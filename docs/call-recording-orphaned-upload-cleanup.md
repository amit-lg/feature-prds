# Call Recording — Cleaning Up Crashed/Orphaned Multipart Uploads

**Related:** `docs/call-recording-chunked-upload-api.md` (the upload flow itself)
**Code:** `src/call-recording-abort/`, `src/command/command.service.ts`, `src/vultr/vultr.service.ts`

**Decision:** Option B ("silence is the signal") is implemented. Option A (a Vultr bucket lifecycle rule) was designed but deliberately **not** built — kept below for context on why it was considered and rejected.

---

## The problem

The chunked call-recording upload flow is `start` → N × [`part-url`, then `PUT` the chunk straight to Vultr] → `complete`. Our backend never buffers the audio bytes — it only authorizes each step and hands back presigned URLs.

That also means our backend never persisted `uploadId`/`fileName` anywhere (before this feature). If the client crashes or gives up mid-upload — after `start`, after a few chunks even — without calling `complete` or `abort`:

- **Nothing in our database changes.** The interaction's `files` column is only written by `completeCallRecordingUpload`, so a crash leaves it exactly as it was — no broken record, no error state, nothing visible in the CRM.
- **But Vultr is left holding a real, open multipart upload session** — whatever parts did upload are sitting there, consuming storage, with no expiry of its own. It stays open **forever** unless something explicitly calls `abort` on that exact `uploadId`.
- Since the client that crashed is the only thing that ever held `uploadId`/`fileName`, that state is gone with it. There is no way to recover or resume that specific session after the fact.

---

## How Vultr actually "knows" an upload is incomplete

Worth understanding before the fix: Vultr (like any S3-compatible store) tracks multipart uploads as an **entirely separate list from real objects**.

- `start` (`CreateMultipartUploadCommand`) doesn't create a file — it opens a session identified by `UploadId`, stamped with an `Initiated` timestamp, living in that separate list. You can't see it via a normal object listing.
- Each `PUT` (`UploadPartCommand`) attaches one more part to that open session — still not a file.
- Only `complete` (`CompleteMultipartUploadCommand`) closes the session and assembles the parts into a real object.

So "incomplete" doesn't mean "missing some chunks" — Vultr has no idea how many chunks you ever intended to send. It means: *this `UploadId` is still in the open-sessions list, and `complete`/`abort` was never called for it.* A session that crashed right after `start` (0 parts) and one that crashed right before `complete` (every part uploaded) look identical to Vultr — both are just "still open."

---

## Implemented: per-upload delayed job, "silence is the signal"

Reuses a pattern already running elsewhere in this codebase for the exact same problem shape (see `src/attempt-expiry/` + `src/attempt-session/`'s `bookExpiry`/`cancelExpiry`, and `docs/quiz-timing-without-sockets.md`).

### The idea

Every `part-url` call is proof the client is still alive and about to upload another chunk. So:

1. On `start` — book a delayed job at `now + GRACE_MS` (10 minutes), keyed by `uploadId`.
2. On every `part-url` call — **remove the existing job and re-add it** at a fresh `now + GRACE_MS`. This is the "touch" that pushes the deadline out.
3. On `complete` — cancel the job (upload succeeded, nothing to clean up).
4. On `abort` — cancel the job (already cleaning up explicitly).
5. **If nothing touches it again** (client crashed), the job's delay simply runs out and a worker fires, calling `vultrService.abortUpload(uploadId, fileName)` automatically.

### Why BullMQ, not RabbitMQ

These are different tools — BullMQ is a Node job-queue library backed by **Redis**; RabbitMQ is a separate AMQP message broker. This backend already runs BullMQ on its shared Redis instance (`src/queue/queue.module.ts` — same Redis used for caching and Socket.IO), so this needed no new infrastructure.

### What's built

- **`src/call-recording-abort/call-recording-abort.constants.ts`** — queue/job names, `callRecordingAbortKey(uploadId)`, `CALL_RECORDING_ABORT_GRACE_MINUTES` (10), the job-data shape.
- **`src/call-recording-abort/call-recording-abort.service.ts`** — `bookAbort(data)` (remove-then-add under `jobId: callRecordingAbortKey(uploadId)`, matching `AttemptSessionService.bookExpiry`'s shape), `cancelAbort(uploadId)`, and `runAbort(data)` (calls `VultrService.abortUpload`, invoked only by the processor when a job actually fires).
- **`src/call-recording-abort/call-recording-abort.processor.ts`** — the BullMQ worker, dispatches by job name to `runAbort`.
- **`src/call-recording-abort/call-recording-abort.module.ts`** — registers the queue, imports `VultrModule`, exports the service.
- **`command.module.ts`** — imports `CallRecordingAbortModule`.
- **`command.service.ts`** — four call sites:
  - `startCallRecordingUpload` — `bookAbort` right after `vultrService.startUpload` succeeds.
  - `getCallRecordingPartUploadUrl` — `bookAbort` right after `vultrService.getUploadPartUrl` succeeds (the reschedule/"touch").
  - `completeCallRecordingUpload` — `cancelAbort` right after `vultrService.completeUpload` succeeds (Vultr has already assembled the real object at that point, regardless of whether the following DB write succeeds).
  - `abortCallRecordingUpload` — `cancelAbort` right after the explicit `vultrService.abortUpload` succeeds.

### The mechanics (as implemented)

```ts
// call-recording-abort.service.ts
async bookAbort(data: CallRecordingAbortJobData) {
  const jobId = callRecordingAbortKey(data.uploadId);
  const existing = await this.queue.getJob(jobId);
  if (existing) await existing.remove();          // cancel the old timer
  await this.queue.add(CALL_RECORDING_ABORT_JOB, data, {
    jobId,                                         // BullMQ dedupes on this
    delay: CALL_RECORDING_ABORT_GRACE_MS,
    attempts: 3,
    backoff: { type: 'exponential', delay: 5_000 },
  });
}

async cancelAbort(uploadId: string) {
  const job = await this.queue.getJob(callRecordingAbortKey(uploadId));
  if (job) await job.remove();
}

// Called only by the processor, when the job survives uncancelled/unrebooked.
async runAbort(data: CallRecordingAbortJobData) {
  await this.vultrService.abortUpload(data.uploadId, data.fileName);
}
```

`jobId: callRecordingAbortKey(uploadId)` is what makes rescheduling work — BullMQ deduplicates by job ID, so `bookAbort` removes the existing job before re-adding rather than just calling `add` again with a new delay.

Both `bookAbort` and `cancelAbort` swallow their own errors (logged as a warning, not thrown) — a job caught mid-flight by BullMQ's own lock when `remove()` runs is the one legitimate race here, and it isn't worth failing the caller's `start`/`part-url`/`complete`/`abort` request over. Worst case on that race: one touch doesn't get to reschedule the deadline, and the very next touch (or the job's own eventual firing, which is harmless either way) sorts it out.

### Reliability properties

- Timer state lives in **Redis**, not process memory — a backend restart/redeploy mid-upload doesn't lose it.
- Every API container can call `bookAbort`/`cancelAbort`, but Redis's own locking ensures only one worker instance ever processes a given `jobId` — no double-abort race.
- Fires almost exactly `CALL_RECORDING_ABORT_GRACE_MS` (10 minutes) after the last real touch — no periodic scanning, no wasted work when nothing is stale.
- No new database table — the timer state lives entirely in Redis via BullMQ.

### Testing

- **`src/call-recording-abort/call-recording-abort.service.spec.ts`** — unit tests for `bookAbort` (books when nothing exists, removes-then-re-adds when a job already exists, doesn't throw on a BullMQ "locked by another worker" race), `cancelAbort` (removes when present, no-ops when absent, doesn't throw on the same race), and `runAbort` (calls `VultrService.abortUpload` with the right args, rethrows on failure so BullMQ's retry/backoff kicks in).
- **`src/command/command.service.spec.ts`** (`describe('call recording upload', …)`) — extended with assertions that each of the four endpoints touches the abort service correctly: `bookAbort` fires on a successful `start` and a successful `part-url`, and is *not* called when either fails; `cancelAbort` fires on a successful `complete` (even if the follow-up DB write then fails — Vultr already assembled the real object by that point) and on a successful `abort`, and is *not* called when the underlying Vultr call itself fails.
- Four other `command.service.*.spec.ts` files (`query-vault-files`, `vault-cache`, `came-call-user-link`, `superseded-lead`) needed a no-op `CallRecordingAbortService` provider added to their `TestingModule` setup purely so Nest's DI can resolve `CommandService`'s new constructor dependency — they don't exercise this feature and needed no behavioral changes.
- No spec file for `call-recording-abort.processor.ts` — matches this codebase's existing convention (`attempt-expiry`, `schedule-call-reminder` don't test their processors either): a processor is a thin `switch` on job name dispatching to an already-tested service method, so there's nothing meaningful left to assert once the service itself is covered.
- Run everything touched: `npx jest src/command src/call-recording-abort src/vultr`. One pre-existing, unrelated flaky failure exists on `main`/`development` independent of this change — a `createEmployee` test in `command.service.spec.ts` that only fails when run in the same process as certain other suites (confirmed by running it in isolation, and by reproducing the same failure on an unmodified checkout) — not something this feature introduced or needs to fix.

### Postman / API contract

**Nothing changes for the client.** This feature adds no new endpoint and no new request/response field — `start`, `part-url`, `complete`, and `abort` all keep the exact same contract documented in `docs/call-recording-chunked-upload-api.md`, including its Postman collection (`src/command/call-recording-postman/collection.json`). The dialer app needs zero code changes to benefit from this; the abort-job booking/cancelling happens purely inside the existing calls it already makes.

### Manual end-to-end verification

Because this is background, timer-driven behavior rather than a request/response you can assert on directly, the meaningful test is against a real (or staging) Vultr bucket:

1. Temporarily lower `CALL_RECORDING_ABORT_GRACE_MINUTES` (`src/call-recording-abort/call-recording-abort.constants.ts`) to something short, like `1`, and deploy to a test environment.
2. Simulate a crash: call `start`, then one `part-url` + `PUT` a chunk to the returned URL — then stop. Do **not** call `complete` or `abort`.
3. Confirm the session exists on Vultr right after: `node scripts/cleanup-incomplete-recording-uploads.js` (dry-run mode, lists without deleting — see the script's own header comment) should show that `uploadId`/`fileName` under `CRM/platform/recordings/` as a currently-open multipart upload.
4. Wait past the grace period (just over a minute, with the setting above), then run the same dry-run script again — the upload session should no longer be listed, and the backend logs should show `runAbort: aborted orphaned upload interactionId=... uploadId=...`.
5. Revert the constant back to `10` before deploying to production.

As a companion check for the "it finished normally" path: repeat steps 1-2 but also call `complete` (or `abort`) before the grace period elapses, and confirm the job never fires — no `runAbort` log line appears, and the upload either becomes a real object (`complete`) or is gone immediately (`abort`), not lingering until the timer would have caught it.

---

## Considered and rejected: Vultr bucket lifecycle rule (Option A)

The alternative was a bucket-level config: tell Vultr *"any multipart upload under the recording prefix still open after N days → abort it automatically."* This would have been a background sweep Vultr runs on its own (roughly daily), independent of whether our backend is even running.

**Why it was rejected in favor of Option B alone:**

- ➖ Coarse-grained — S3-style lifecycle rules are typically evaluated about once a day, so cleanup would land within ~24-48h, not minutes. Option B's ~10 minute grace period was judged good enough on its own that the extra day-scale backstop wasn't worth the added moving part.
- ➖ Unverified provider support — not every S3-compatible store fully honors `AbortIncompleteMultipartUpload` lifecycle rules, and Vultr Object Storage's support for this was never independently confirmed before the decision was made to skip it.
- ➕ (for the record) it would have needed zero backend code — a single `PutBucketLifecycleConfigurationCommand` call, one time, ever. If Option B is ever found to be insufficient (e.g. a Redis data-loss event wiping booked jobs), this is the natural fallback to revisit.
