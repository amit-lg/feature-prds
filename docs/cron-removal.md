# Cron removal — working document

**Goal:** remove every scheduled job from this project.
**Status:** in progress. We are going through them one at a time.

Each entry below has three parts:

- **What it does** — the current behaviour, read from the code.
- **Context** — why it exists, in business terms. Filled in by the team as we get to each one.
- **Solution** — filled in once we have agreed on it. Empty until then.

Nothing here is decided until the Solution section says so.

---

## Shared infrastructure: the job queue

**Agreed in (8): BullMQ is adopted for the cron removal as a whole, not for one entry.** Several entries need work to happen at a moment derived from data rather than at a fixed time of day, which is what a delayed job is and what `@Cron` cannot express: `submitAfterDelay` (10) is literally a delayed job, the two-hour WhatsApp reminder inside `handleQuizes` (4) and `handleScheduleCallNotification` (2) are the same fixed-offset-before-a-known-time problem, and `handleDailyTasksAtEightPM` (7) is the same "send a batch and record what went out".

**Use delayed jobs, not BullMQ's repeatable jobs.** BullMQ has a cron/repeat feature; using it would relocate the schedule rather than remove it.

`ioredis` is already a dependency ([`package.json:59`](../package.json)) and already used directly in three places — [`job-view-buffer.service.ts:40`](../src/job/job-view-buffer.service.ts), [`system-config.service.ts:55`](../src/interview-bot/system-config/system-config.service.ts) — which is the connection type BullMQ requires. `bullmq` itself is the one new package.

---

### One Redis, not two

**Reversed.** The queue ran on a dedicated Redis instance (`redis_queue`, the
`redis-queue` service on host port 6380) for the length of this work. It no
longer does: `src/queue/queue.module.ts` reads `process.env.redis`, the same
instance as the Keyv cache, the Socket.IO adapter, the job-view buffer and the
interview-bot system config. The `redis_queue` variable is gone and the
`redis-queue` service is deleted from `docker-compose.yml`.

The original argument is kept below, because it is still the right argument —
what changed is the facts it was applied to, not the reasoning.

**What the argument was.** There is one Redis today and four things share it,
all of which hold data that is cheap to lose. A delayed job is not: a quiz
reminder is scheduled up to seven days ahead. Two different things can lose one,
and the eviction policy only addresses one of them.

| | Setting | Guards against |
|---|---|---|
| 1 | `maxmemory-policy noeviction` | An `allkeys-*` policy discarding keys to stay under `maxmemory`. Redis cannot tell a promise from a cache entry. Only bites when `maxmemory` is set — with no limit (the default) nothing is evicted whatever the policy says, and the failure mode is an OOM kill instead. |
| 2 | `appendonly yes` (with `appendfsync everysec`) | A restart or crash, which the eviction policy does nothing about and which is the likelier of the two over a week. RDB snapshotting alone can lose everything since the last save point; AOF bounds it to about a second. |

**Why it no longer justifies a second instance.** Read the compose file rather
than the argument: the `redis` service sets no `command:` override, no config
mount and no memory limit. Redis defaults to `maxmemory 0` and
`maxmemory-policy noeviction`, so **row 1 was already satisfied on the cache
instance and nothing has ever been evicted from it** — the table's own footnote
says as much. Only row 2 was genuinely missing, and row 2 is two flags on a
service we already run, not a second service.

So the trade was: a whole second Redis instance, a second volume, a second env
var, and a per-environment provisioning step — to buy an eviction guarantee that
was already true by default, plus a persistence setting that costs one line.

**And the per-environment step never happened.** `redis_queue` was set on the
development machine's `.env` and nowhere else. Dev, staging and Coolify were both
marked NOT DONE below, which means BullMQ there was passing `url: undefined` to
ioredis and falling back to `localhost:6379` — the cache instance, or nothing at
all. **The deployed environments were already running one Redis, accidentally.**
This change makes the configuration honest rather than changing what runs.

**What the shared instance has to keep.** Both requirements move onto the `redis`
service, set through `REDIS_ARGS` (redis-stack-server's documented mechanism — a
`command:` override would drop the image's module loading):

```yaml
environment:
  REDIS_ARGS: >-
    --maxmemory-policy noeviction
    --appendonly yes
    --appendfsync everysec
```

Two ways to undo that by accident, both written above the service in
`docker-compose.yml` so they are found by whoever is about to do it:

- **Setting a `maxmemory` limit with an `allkeys-*` policy** to bound cache
  growth. That is a reasonable thing to want and it silently makes every delayed
  job evictable. Bound it and keep `noeviction`, or give the queue its own
  instance again.
- **`FLUSHDB` / `FLUSHALL`.** Routine against a cache. It now also drops the
  lead-reset day guard, and the next lead request unassigns every lead in the
  system (entry 1d).

**Still true, and unchanged by any of this:** if an environment is on a managed
Redis that forces an eviction policy and cannot offer `noeviction`, delayed jobs
are not safe there. That was a reason to check before, and it is the same reason
to check now — it just no longer implies provisioning a second instance as the
first move. `CONFIG SET` applies immediately but is lost on restart, so anything
set at runtime must also reach the config file or be committed with
`CONFIG REWRITE`.

**What has to change, and where — all DONE.** The per-environment checklist this
section used to carry is gone rather than completed: there is no new variable to
distribute and no second service to provision. `docker-compose.yml`, `CLAUDE.md`
and `src/queue/queue.module.ts` are updated; the local `.env` loses its
`redis_queue` line; the `redis_queue_volume_data` volume is deliberately left in
place, since any delayed jobs the old instance still holds are recoverable from
it. Dev, staging and Coolify need their existing Redis checked for `appendonly`
and for an unexpected `maxmemory` limit — a check, not a provisioning step.


### And none of the above is the actual guarantee

No Redis configuration survives losing the instance, so every entry that puts work on the queue needs its own answer to "what if the queue is empty and shouldn't be". Where the due time is derivable from data already in Postgres — which is true of (8), (4), (2) and (10) — that answer is a **reconcile step**: recompute which jobs should exist and re-add them, using derived job IDs so the operation is a no-op when nothing is wrong and a full repair when something is. Run it on boot and expose it as an endpoint. It is not a schedule; it is idempotent repair, in the same spirit as the `SET NX` guard agreed in (d).

`noeviction` and AOF reduce how often reconcile has to save us. They do not remove the need for it.

---

## The environment variables this work added

Summarised in [`CLAUDE.md`](../CLAUDE.md); the reasoning is here. They are read
directly off `process.env` like every other setting in this project — there is
no config schema. They were **one connection string, four flags, and a
credential**; the connection string is gone ("One Redis, not two" above), and
the four flags are gone too (see "The four flags — removed" below), so what
remains is the credential.

| Var | Read in | Test | Default | Gates |
|---|---|---|---|---|
| `exchange_rate_api_key` | [`exchange-rate.util.ts`](../src/common/utils/exchange-rate.util.ts) | presence | falls back | entry 1c |

### `redis_queue` — removed

The connection for every delayed job, until "One Redis, not two" above reversed
it. `queue.module.ts` now reads `process.env.redis` and there is no queue-specific
variable to set anywhere.

**Kept in this document because its failure mode is the lesson, not the
variable.** `connection: { url: undefined }` is not an error — ioredis falls back
to localhost:6379, so a missing variable produced a queue that connected to the
wrong instance and said nothing. Nothing logged, nothing threw, and the first
sign of trouble would have been a reminder that never arrived. That is what a
variable which reaches each box by hand buys you, and it is why the reversal
removes the variable rather than documenting it harder. The same fragility still
applies to `TZ` and to `exchange_rate_api_key`, which are also gitignored and
also reach each box by hand.

### The four flags — removed

Entries 1d, 2, 6 and 7 each shipped with a flag
(`whatsapp_reminders_enabled`, `schedule_call_reminders_enabled`,
`lead_reset_enabled`, `schedule_lead_dispatch_enabled`). All four have since
been removed from the code — `remindersEnabled`, `callRemindersEnabled`,
`leadResetEnabled` and `scheduleLeadDispatchEnabled` no longer exist, every
call site that checked one now runs unconditionally, and the two that were
also set in `.env` have been deleted from it. Kept here for the history, since
the reasoning behind the (deliberately inconsistent) polarity is still useful
context for anyone touching these services:

**Off by default, `=== 'true'`** — these were rollout gates, and they failed
closed so that an unset variable, a typo or a fresh environment could not start
sending.

- `whatsapp_reminders_enabled` (entry 7). The replacement writes a `MessageSend`
  ledger row per message so a re-run cannot double-send, and that migration
  (`20260902200000_add_message_send`) is **still not applied in every
  environment** — this now sends unconditionally, so it will fail on its first
  write wherever the migration is outstanding. The cron it replaces was already
  deleted before the flag was removed, so there is no double-send risk, only a
  missing-table risk. It also still needs an external scheduler calling
  `POST command/whatsapp-reminders/run` at 20:00 IST — the module deliberately
  has no timer of its own.
- `schedule_call_reminders_enabled` (entry 2). Same migration dependency.
  `handleScheduleCallNotification` never actually fired (see "Why the cron
  never fired"), so this sending unconditionally is a **first** send rather
  than a resumed one — customers now receive a message they have never had.
  It needs no external scheduler — the job is written when the booking is
  created.

**On by default, `!== 'false'`** — these were ops escape hatches, not rollout
gates, for operations that were already live and doing real work. Removing them
means there is no longer a request-path way to turn either off without a
redeploy.

- `schedule_lead_dispatch_enabled` (entry 6). `handleHalfHourlyTasks` was live
  and handing out leads every fifteen minutes; the replacement carries the same
  behaviour with no flag now guarding it. No migration and no external
  scheduler either way (`UserLead.employeeId` and the activity/interaction rows
  already *are* the record).
- `lead_reset_enabled` (entry 1d). The midnight lead reset inside
  `handleRefreshToken` was live and wiping ownership every night; the
  replacement now always runs it, with no flag left to stop the destructive
  daily wipe short of a redeploy.

**And one flag that was never part of this group**, because it is a credential
rather than a switch:

- `exchange_rate_api_key` (entry 1c). Read first, but with the key that was
  hardcoded in the cron as a logged fallback. It is the one variable in this
  work that does NOT fail closed, and that is deliberate: it sits on the
  non-INR payment path, `.env` is gitignored, and the `redis_queue` lesson is
  that a variable which reaches each box by hand will be missing somewhere.
  Failing closed there means checkout stopping. The follow-up is to rotate the
  key, set the variable everywhere, then delete the fallback.

### Two things that were true of all four flags, while they existed

- **Each was checked twice: once when a job would be written, and again in the
  processor when one fired.** Turning a flag off therefore stopped jobs already
  sitting in the queue, not merely new ones. Both checks are gone along with
  the flags — there is nothing left to stop a queued job from running.
- **They gated behaviour, not wiring.** The modules were always imported by
  `AppModule` and the queues always registered, so this was never about
  whether a feature booted — only whether it acted. That has not changed; only
  the "whether it acted" part is now unconditional.

### And one replacement that has no flag at all

Entry 8 (`sendQuizUpdates` → `src/quiz-reminder/`) reads no environment variable.
It is worth knowing that this was not an oversight: it needed no new table, and
it replaced a job that was already sending, so there was nothing for a gate to
protect. Four variables for five replaced crons is the correct count.

---

## A. `@Cron` jobs — `src/tasks/tasks.service.ts`

There were eight, all registered by `ScheduleModule.forRoot()` in [`app.module.ts:59`](../src/app.module.ts), so every container that booted ran all eight. Entries 1, 2, 6, 7 and 8 are gone.

---

### 1. `handleRefreshToken` — daily at midnight — **REMOVED**

**What it does**
Four unrelated things in one job: unassigns every lead from every employee, resets the Redis `daily_order_counter` to zero, deletes login tokens older than 30 days, and downloads the day's USD exchange rate into the cache. It calls the lead reset twice, and the first call is not awaited.

**Context**

Four separate jobs, four different reasons:

- **`daily_order_counter`.** Order numbers carry a per-day sequence. `generateOrderNumber` ([`user.service.ts:2578`](../src/user/user.service.ts)) builds `<prefix>-51<MM><YY><DD><NNN>` where `NNN` is `INCR daily_order_counter`, so the accounts team can read the day's order IDs straight off the number. The counter must go back to `001` **exactly** when the date in the number changes — at 00:00 IST.
- **Login token cleanup.** Housekeeping on `UserRefreshToken`: drop rows older than 30 days.
- **USD exchange rate.** Foreign-currency pricing goes through Razorpay in the customer's currency, so the day's USD conversion table has to be in the cache before any non-INR payment is priced.
- **Lead reset.** `resetLeads` ([`lead.service.ts:41`](../src/lead/lead.service.ts)) nulls `employeeId` on every assigned lead and flips every `isDone: null` interaction to `false`. Confirmed intended: lead ownership is deliberately wiped every night so the calling day starts clean, and it has to land at 00:00.

So two of the four have a hard 00:00 requirement (the counter and the lead reset) and two have none at all (token cleanup, exchange rate).

**Solution**

**Revised. The earlier plan deferred (a) and kept (d) in the cron; the team overruled both.** All four pieces came out, and `handleRefreshToken` is deleted rather than renamed.

| | Piece | Status |
|---|---|---|
| (a) | `daily_order_counter` | **DONE.** No longer deferred. The key keeps its name and gains an `EXPIREAT` at the next IST midnight, set atomically alongside the `INCR` in `generateOrderNumber`. The duplicate-`orderId` exposure is split out rather than blocking this. |
| (b) | Login token cleanup | **DONE.** Not "delete and replace with nothing" — the team wanted the abandoned rows actually collected. A throttled, bounded, global sweep on the login path. |
| (c) | USD exchange rate | **DONE.** A reusable read-fetch-cache helper called at the point of use. No `ExchangeRateService`: the team declined a new injectable. |
| (d) | Lead reset | **DONE.** Confirmed as genuine 00:00 work, and confirmed that the unawaited call was deliberate — the wipe must not block a request. A per-IST-day guard plus a BullMQ job, triggered by an external scheduler and by the lead-distribution path. |

**Correction to the earlier draft, recorded because it changed the design.** That draft called the unawaited `resetLeads()` at [`tasks.service.ts:44`](../src/tasks/tasks.service.ts) "plainly a bug". Half right: the **duplicate** call is a mistake and is gone, but *not awaiting* it was intentional — the wipe touches ~100K rows and nothing should wait on it. So (d) keeps the work off the caller's path by design, rather than awaiting it.

`handleRefreshToken` is now deleted, and with it the `LeadService` and `HttpService` dependencies `TasksService` only held for it.

---

**a. `daily_order_counter` — DONE this pass**

**Decision, overruling the deferral below: keep the key exactly as it is and let it expire instead of being zeroed.** The team's instruction was that the counter is *supposed* to live for a day and produce a per-day sequence, so the fix is to say that in the key's lifetime rather than in a cron. The duplicate-`orderId` exposure the deferral was waiting on is real, but it is a separate risk with a separate fix, and holding the cron hostage to it kept a nightly job alive for no benefit.

**As built** — [`src/common/utils/daily-order-counter.util.ts`](../src/common/utils/daily-order-counter.util.ts), called from `generateOrderNumber` ([`user.service.ts:2578`](../src/user/user.service.ts)):

```lua
local value = redis.call('INCR', KEYS[1])
redis.call('EXPIREAT', KEYS[1], ARGV[1])
return value
```

One `EVAL`, so the increment and the expiry cannot be separated by a crash. `INCR` on a missing key returns 1, which is precisely what the cron's `SET 0` was arranging.

**Why `EXPIREAT` and not `EX 86400`.** A rolling 24-hour TTL starts at the day's *first* order. If that is 09:00, the key expires at 09:00 the next day — the sequence would run across midnight and then restart mid-morning, repeating numbers inside the same printed date. Gaps are harmless; duplicates are not.

**Why this is safer than the cron rather than merely equivalent.** The expiry is derived from the same `+330`-minute shifted date the order number slices `MM`/`YY`/`DD` out of. Today the date in the number and the moment the counter resets are two facts held in step by a clock, so a deploy across midnight or a container down at 00:00 desynchronises them. Now they are one fact. Nothing depends on `TZ`.

**The cutover is free**, which is what the earlier draft's warning was about. `EXPIREAT` runs on every call, not only when the counter comes back as 1, so the key that exists in production today with no TTL simply picks up the right expiry on the next order. Nothing to seed, no mid-day restart, no duplicated numbers. It is also self-healing: a key that somehow lost its TTL gets one back on the next order.

*Verified against Redis 8.8.2 with the node-redis client the cache uses: a pre-existing untimed key at 46 continued to 47, 48 and came back with a TTL landing on 18:30 UTC (00:00 IST); after the key was dropped the sequence restarted at 1.*

**Still outstanding, and now tracked on its own rather than blocking this** — everything below in this section: `UserPayments.orderId` has no unique constraint and no index while being a lookup key on paths that move money; `padStart(3, '0')` overflows past 999 orders in a day; Redis losing the key mid-day still restarts the sequence at 001, which the cron never protected against either. The durable fix is to source the sequence from Postgres.

---

**The original deferral, kept for the reasoning it records**

The reason it was deferred is that tracing the order number end to end turned up a risk that is bigger than the cron.

**How the order number is actually used**

Generated by `generateOrderNumber(prefix)` ([`user.service.ts:2578`](../src/user/user.service.ts)) as `<prefix>-51<MM><YY><DD><NNN>`, where `prefix` is `PaymentGatways.prefix` and `NNN` is `INCR daily_order_counter` padded to 3. Two callers, both inside `generatePayment`:

- Razorpay ([`user.service.ts:3163`](../src/user/user.service.ts)) — the string becomes both the Razorpay order `receipt` and `UserPayments.orderId`.
- Manual ([`user.service.ts:3235`](../src/user/user.service.ts)) — `UserPayments.orderId`.

**The counter is global.** One key across every platform and every gateway, so a day's numbers interleave — Razorpay takes 001, manual takes 002, another platform takes 003. Fine if accounts reads one combined daily list; there is no dense per-platform sequence if anyone expects one. Worth confirming which they read it as.

It is stored as `UserPayments.orderId String` ([`schema.prisma:337`](../prisma/schema.prisma)) with **no unique constraint and no index** — nothing across the 200+ migrations adds either. A duplicate order number is silently accepted by the database.

And it is not just a label. Four different kinds of consumer:

1. **A lookup key on paths that move money**, all `findFirst` with no `orderBy`: `fixPayment` ([`payment.service.ts:2606`](../src/payment/payment.service.ts)), `makeManualPaymentSuccess` ([`payment.service.ts:2663`](../src/payment/payment.service.ts)) — which marks the payment successful and enrols the courses — and `addmissingUser` ([`payment.service.ts:3375`](../src/payment/payment.service.ts)). `orderCancel` ([`payment.service.ts:1979`](../src/payment/payment.service.ts)) and `confirmPayment` ([`payment.service.ts:2001`](../src/payment/payment.service.ts)) also match on `userId`, so they are much narrower.
2. **Sent outward to third parties**: `RefNo=${orderId}` in the software-provisioning URL ([`payment.service.ts:765`](../src/payment/payment.service.ts)), `enrollmentId: payment.orderId` in several places, the Razorpay `receipt`, and Shipway via `pushOrderToShipway` ([`courier.service.ts:1253`](../src/courier/courier.service.ts)).
3. **Customer-facing**: in the order-confirmation email ([`payment.service.ts:1750`](../src/payment/payment.service.ts)) and in WhatsApp messages ([`payment.service.ts:1831`](../src/payment/payment.service.ts), [`:3335`](../src/payment/payment.service.ts)).
4. **Support and accounts search**: `getPayments` matches `searchString` against `orderId` ([`payment.service.ts:3835`](../src/payment/payment.service.ts), [`:4820`](../src/payment/payment.service.ts)).

**The two failure modes are different, and only one is dangerous**

- **The reset is missed** — a deploy across midnight, a container down at 00:00. The counter keeps climbing and the next day starts at `047`. That produces **gaps**: visible to accounts, indistinguishable from a lost order, harmless to the system.
- **The counter resets mid-day** — numbers repeat within the same date, producing **duplicates**. Given consumer (1) above, a duplicate means support search returns two payments and `fixPayment` / `addmissingUser` act on an arbitrary one of them.

The path that matters most here is one the cron does nothing about: **Redis losing the key restarts the sequence at 001 mid-day.** `daily_order_counter` has no TTL but also no durability guarantee, and `INCR` on a missing key returns 1 — so a restart without persistence, an eviction, or a failover to an empty replica silently reissues that day's numbers from the start.

**Why this is deferred rather than done**

Date-keying the counter (`INCR daily_order_counter_<YYYY-MM-DD>`, derived from the same IST-shifted value the order number already uses, with a 48h TTL) is still the right move and still removes the cron. It eliminates gaps outright and removes the clock-drift reset, because the date and the sequence stop being two facts held in step by a clock.

But it does **not** make order numbers collision-proof, and neither does the cron today. Duplicates would still be possible and still silently accepted. Doing the easy half now would remove a cron and leave the real exposure in place, so the counter is better handled as one piece of work that settles both:

- Date-key the counter (removes the cron, removes gaps).
- Decide whether duplicates matter enough to enforce — a unique constraint on `orderId` with a retry, or sourcing the sequence from Postgres instead of Redis. A small `(date, value)` row with an atomic upsert-returning increment is durable, needs no cron, and keeps the date-derived reset.

**Also to fold into that work**

- `padStart(3, '0')` overflows to four digits past 999 orders in a day.
- `getInvoiceCounter` ([`payment.service.ts:5838`](../src/payment/payment.service.ts)) is a fair precedent for bootstrapping a counter key inline with no cron, but it shares the same durability weakness on financial-year invoice numbers and its `exists` → `set 0` → `incr` sequence races between the check and the set.
- **Not cron scope, but found while tracing and it sharpens the above:** `PaymentController` has no guards and `PaymentModule` has no `configure()`, so no `PlatformCheckMiddleware` either. `POST /api/payment/fixissue` and `POST /api/payment/someuser` are unauthenticated, take an order number in the body, and mark payments successful / enrol courses. Worth its own ticket regardless of what happens to the counter.

*If the counter is ever moved, note the cutover:* the new key does not exist on first use, so the sequence starts at `1`. Deploying mid-day would restart that day's sequence and duplicate numbers already issued. Either deploy just after 00:00 IST or seed the key with the current value.

---

**b. Login token cleanup — a self-cleaning table, not a deletion**

**Status: DONE this pass.** Built as [`src/common/utils/refresh-token-sweep.util.ts`](../src/common/utils/refresh-token-sweep.util.ts), called from `giveUser` ([`auth.service.ts:2900`](../src/auth/auth.service.ts)) right after the new session row is written, and never awaited.

**Decision, overruling "delete and replace with nothing" below: the abandoned rows have to actually be collected.** The analysis in this section stands — expiry is enforced at read time, so nothing about correctness depends on the cleanup — but the team's requirement is that rows belonging to users who never come back do get removed, and deleting the cron without a replacement leaves them forever.

The shape that satisfies that without a schedule: **a throttled, bounded, global sweep on the login path.** The trigger is a login; the *scope* is global, not that user. New sessions are the only thing that grows the table, so cleanup is paid in proportion to growth, and users who never return are cleaned by users who do. That is what the correction below rules out for a *per-user* delete, and exactly why the sweep must not be scoped to the caller.

Three properties make it safe:

- **Throttled cluster-wide.** A `SET NX` with a short TTL before doing anything, so one sweep happens per window no matter how many people log in. Every other login pays a single Redis `SET`.
- **Bounded.** At most N rows older than 30 days per sweep, oldest first. A backlog drains over successive sweeps rather than in one long-locking hit.
- **Off the request path.** Started and not awaited, with a `.catch()` that logs — same shape as (d), and for the same reason.

**The window is a function of one missing index.** `UserRefreshToken` has exactly one index, `UNIQUE(token)` ([`20250222182917_fixing_tokens`](../prisma/migrations/20250222182917_fixing_tokens/migration.sql)), so filtering on `createdAt` is a sequential scan. A five-minute window would mean ~288 scans a day, which is worse than the cron it replaces. So: **hourly to start** (~24/day, already fewer than the cron's once-per-container-per-night on any multi-container deploy), plus a migration adding an index on `createdAt` that makes each sweep a cheap range scan and the window a free choice. The migration ships with the code and applies when the DB role allows.

Worth adding in the same migration, unrelated to cleanup: `giveUser`, `wsLogin`, `logout` and `wsLogout` all query on `(userId, platformId)` and every one of them sequential-scans today.

**As built**

| | |
|---|---|
| Trigger | `giveUser`, immediately after `userRefreshToken.create` — the one place a session row is written |
| Scope | Global. Every row older than 30 days, not the caller's |
| Throttle | `SET refresh_token_sweep NX PX 1h` on the cache Redis; one sweep per hour cluster-wide |
| Batch | 1000 rows, oldest first. A backlog drains over successive logins |
| Failure | Logged and swallowed. Table hygiene must never fail a login |

The throttle **fails closed**: no raw client, or Redis unreachable, means nobody sweeps. Skipping a round of hygiene costs nothing; letting every login in the cluster run an unthrottled delete against Postgres does not.

`prisma/migrations/20260903130000_user_refresh_token_indexes` adds both indexes. The code is correct without it — that is what the hourly window buys — but the window should come down once it is applied.

---

**The original proposal, kept for the analysis it records**

Expiry is **already enforced at read time**. `refreshtoken()` ([`auth.service.ts:3224`](../src/auth/auth.service.ts)) deletes the row, then rejects it with `Token has expired!` if `createdAt` is over a month old — before issuing anything. And every other reader is gated by something shorter than 30 days anyway: `wsLogin` ([`auth.service.ts:4846`](../src/auth/auth.service.ts)) matches on `jwtToken`, and the JWT itself lives 3 days ([`app.module.ts:56`](../src/app.module.ts)); `logout` ([`user.service.ts:107`](../src/user/user.service.ts)) and the presence check ([`communicate.service.ts:700`](../src/communicate/communicate.service.ts)) do the same or do not care about age.

So the cron deletes rows that are already unusable. Nothing about security or correctness depends on it running — on time, or at all. It is table hygiene and nothing else.

**Correction to the earlier draft of this section.** It proposed doing the cleanup opportunistically on the login path, widening the delete `giveUser` ([`auth.service.ts:2854`](../src/auth/auth.service.ts)) already performs. That does not actually work, and the reason is worth writing down: the rows that accumulate are **abandoned sessions** — users who never came back. A per-user cleanup on login only ever touches users who *do* come back, and those are exactly the users whose old row is already deleted by `giveUser` (single-login platforms) or by `refreshtoken()` (which deletes the row it reads, expired or not). The backlog would be untouched, and the login path would pay for it.

So: **remove the `deleteMany` from the cron and add nothing in its place.**

If table growth needs bounding later, it belongs in the database rather than the app — the app has no reason to know about it, and any in-process version is another schedule to remove. Two facts for whoever picks that up:

- `UserRefreshToken` has exactly one index, `UNIQUE(token)` ([`20250222182917_fixing_tokens`](../prisma/migrations/20250222182917_fixing_tokens/migration.sql)). The nightly `deleteMany` filters on `createdAt`, so it is a full table scan every night, once per container.
- An index on `(userId, platformId)` is worth adding on its own merits, unrelated to cleanup: `giveUser`, `wsLogin`, `logout` and `wsLogout` all query on that pair today and every one of them is a sequential scan.

A one-off manual clear of the existing backlog at deploy is worth doing, but it is an ops step, not a code change, and nothing breaks if it is skipped.

---

**c. USD exchange rate — the lazy path already exists, and the cron is masking two bugs**

**Status: DONE this pass.**

`getDollars` ([`platform.service.ts:9499`](../src/platform/platform.service.ts)) already does exactly what the cron does — read the cache, fetch from `exchangerate-api.com` on a miss, cache for 24h. The cron is a warmer for a cache that warms itself.

But the consumers are inconsistent, and the cron is the only reason that has not surfaced:

- **Four sites read the cache with no fallback at all** — [`payment.service.ts:1012`](../src/payment/payment.service.ts), [`payment.service.ts:2119`](../src/payment/payment.service.ts), [`command.service.ts:7956`](../src/command/command.service.ts), [`command.service.ts:8335`](../src/command/command.service.ts). On a miss they pass `null` into `calculateAmount` ([`payment.service.ts:5908`](../src/payment/payment.service.ts)), which immediately does `currencyExchangeRate[currency]` → `TypeError` on null. A foreign-currency invoice or courier flow crashes outright.
- **The one site that does have a fallback has it wrong.** [`user.service.ts:2905`](../src/user/user.service.ts) assigns `await this.platformService.getDollars()` directly, but `getDollars` returns `{ cachedExchangeRate }` — a wrapper, not the rate table. So on a cache miss `currencyExchangeRate['USD']` is `undefined` and the price comes out `NaN`. Silently. This is live today and only invisible because the cron keeps the key warm.

So removing the cron here is not just a deletion — it requires making the read genuinely lazy first.

**As built** — [`src/common/utils/exchange-rate.util.ts`](../src/common/utils/exchange-rate.util.ts), a reusable `getExchangeRates(cacheManager, httpService)`:

1. Read the cache, fetch and cache for 24h on a miss, return **the rate table itself** — never a wrapper, never `null`. If the rates cannot be obtained it throws a 503, because `calculateAmount` cannot do anything sensible with a `null`.
2. It holds the in-flight promise, so a cold cache under load fires one upstream call rather than one per request. That burst is new: it is exactly what the nightly warm used to hide.
3. It refuses to cache a malformed response. Writing junk under a 24-hour TTL would break every conversion for a day.
4. All six call sites go through it — `payment.service.ts` ×2, `command.service.ts` ×2, `user.service.ts`, and `getDollars` itself, which keeps returning `{ cachedExchangeRate }` because `GET platform/dollars` returns that shape to clients. The wrapper/`NaN` bug is fixed as a side effect.
5. The API key moves to `exchange_rate_api_key`.

**Not an `ExchangeRateService`, by decision.** The team declined a new injectable; the instruction was to read the cache and fetch on a miss at the point of use. A plain exported function is what makes that possible without six copies of the fetch: every caller (payment, command, user, platform) already has `cacheManager` and `httpService` injected, so there is no provider, no module wiring and no `PlatformModule` import anywhere. Same shape as `assertPermission` in the same directory.

**One deliberate compromise on the API key.** `exchange_rate_api_key` is read first, but the hardcoded `e0c40d6b5ca88e568f19f53e` remains as a fallback with a logged warning. `.env` is gitignored and there is no `.env.example`, so a new variable reaches each box by hand — and this one sits on the payment path, where the `redis_queue` failure mode (unset variable, silence, then a surprise) would mean non-INR checkout stopping. The key is in git history regardless. **Follow-up: rotate the key, set the variable everywhere, then delete the fallback and let a missing variable throw.**

*Still worth deciding separately:* a longer-lived last-known-good copy (a 7-day key, or a row) so an upstream outage after the 24h TTL lapses does not stop non-INR payments. Not built — the cron gave no such protection either, so this is parity, not a regression. It matters more now only because the fetch is on the request path rather than at midnight.

---

**d. The lead reset — keep the midnight behaviour, drop the in-process schedule**

**Status: DONE this pass.** Built as `LeadResetService` in [`src/lead-assignment/`](../src/lead-assignment/) — originally its own `src/lead-reset/` module, merged with entry 6 (see "The two lead modules were merged" at the end of entry 6) — and with it the `@Cron` is deleted.

**Two corrections to the design below, both from the team.**

1. **The unawaited call was deliberate.** This section calls it "plainly a bug"; that is only half right. The **duplicate** call was a mistake and has been removed, but not awaiting the wipe was intended — it touches ~100K rows and no request should wait on it. So the replacement keeps the work off the caller's path rather than awaiting it. (Worth being precise about the reason: a single `updateMany` does not block Node's event loop, so the cost is the caller's latency and the load on Postgres, not the process. The conclusion is the same.)
2. **It runs as a BullMQ job, not a floating promise.** A bare unawaited promise is how an exchangerate-api outage silently ate the reset in the first place. A job with a per-day job id gets retries, logging and dedupe, and a crash mid-wipe is retried rather than left half-done with the day's guard already claimed.

**So the shape is:** the `SET NX` date guard below, then a job that does the wipe **in pages** rather than as one `updateMany` over the whole table — same total work, no single long transaction across 100K rows — ending in the `onLeadsReset()` call `resetLeads` already makes. Two triggers, as below: an external scheduler at 00:00 IST, and a cheap guard check on the five lead-distribution paths as the safety net.

**Where the guard key lives matters.** Losing it mid-day means a second full wipe of every assignment while agents are mid-call. It rides the queue's own connection, which since "One Redis, not two" above is the shared `redis` instance — safe there only because that instance sets no `maxmemory` limit and now runs AOF, so nothing evicts it. No migration needed, unlike a Postgres marker; the two ways to break it by hand (a memory limit with an `allkeys-*` policy, and `FLUSHDB`) are written above the service in `docker-compose.yml`.

**One honest limit of the non-blocking design.** Because the wipe does not block, a lead request arriving while it is still running can be served mid-wipe, so "wiped before any lead is handed out" is a strong tendency rather than a guarantee. That is already true today — the midnight call is unawaited — so it is not a regression, but making it a guarantee would mean blocking that first request, which is explicitly not wanted.

**Still open, and confirmed as a question for the team** — the two decisions at the end of this section. Built with today's unconditional semantics; the appointment exclusion is one line to flip.

**As built**

| | |
|---|---|
| Queue | `lead-reset`, one job per IST day, `concurrency: 1` |
| Job id | `lead-reset-<YYYY-MM-DD>`, so a re-add is ignored while the record lives |
| Guard | `SET lead-reset:day:<YYYY-MM-DD> NX EX 48h` on the queue's connection (the shared `redis`), claimed at trigger time |
| Triggers | `POST command/lead-reset/run` (external scheduler, 00:00 IST) and `triggerFromLeadRequest()` on the five lead-distribution paths |
| Wipe | Paged by `id > cursor`, 500 a page, then `ScheduleLeadDispatchService.onLeadsReset()` |
| Flag | none — `lead_reset_enabled` has been removed; the reset always runs |
| Observability | The guard key in Redis holds the day's record: state, trigger, timestamp, rows touched. `GET command/lead-reset/status` exposed it until it was removed on 2026-10-01 |

**Why the guard is claimed at trigger time and not in the worker.** The wipe is convergent — every step is "make these rows look like this" — so a retry after a partial run simply finishes it, and BullMQ must be allowed to retry the same job. What must *not* happen is a second trigger on the same day starting a second wipe. Claiming at trigger time distinguishes those two cases; claiming in the worker would conflate them and a crash mid-wipe would leave the day claimed and half-done.

Two releases close the gaps that leaves. If `queue.add` throws after the claim, the day is released immediately — a claimed day with no job behind it is a silently skipped reset, which is exactly the cron's failure mode. And if every attempt of the job fails, the processor releases the day before rethrowing, so a later lead request can re-claim it rather than waiting 48 hours for the key to expire.

**Why paged by cursor rather than one `updateMany`.** Not for the row count — the total work is the same — but to avoid one transaction across ~100K rows. Walking `id > cursor` forward also means the loop terminates even if a row is reassigned mid-wipe, which a "re-query the first page until it comes back empty" loop does not. It matters most for `UserLeadInteraction`, which has no index on `isDone`: a repeated `WHERE isDone IS NULL LIMIT n` would be a fresh sequential scan per page, whereas the cursor walks the primary key so the whole wipe is one pass.

**The per-process memo.** The lazy trigger sits on one of the busiest paths in the app, so after the first lead request of the day a container answers from memory and never touches Redis again. It is a cache of a decision, not the decision — the guard in Redis is what actually claims the day, so a fresh container pays one `SET NX` to learn what the others already know.

**Fails closed.** If the queue's Redis cannot be reached, nobody claims and nothing is wiped. A wholesale unassign is destructive and easy to repeat later; running it twice because Redis was unreachable is much worse than running it an hour late.

**If Redis loses the queue**, both the guard and the job go with it, and the next lead request re-claims and re-runs the day. That is self-healing in the direction that matters — but note the other direction: losing the instance *after* a successful wipe means the day looks unclaimed, and the next lead request runs a second wipe, dropping assignments agents are working. The shared instance runs AOF and sets no `maxmemory` limit precisely so this is a lost-instance event rather than a routine one. The durable fix is a row in Postgres rather than a key in Redis, which is a migration and was not worth blocking this on.

**Known limits, accepted deliberately**

- **The wipe is not ordered against lead handout.** Non-blocking means a request arriving mid-wipe can be served mid-wipe. Already true of the cron, which never awaited it either.
- **Booked appointments are still wiped.** `dissolveLeads` excludes leads with an `appointmentTime`; this does not, matching today's `resetLeads`. Pending the team's answer; one line to change.
- **In-flight assignments are still wiped**, including a lead picked up five minutes before midnight. Same answer pending.
- **No reconcile endpoint**, unlike entries 2, 6 and 7. There is nothing to rebuild: the trigger is a `SET NX` away and the lazy path runs it. `force=true` covers the one case the guard would otherwise block.

**Confirmed by the team:** the nightly wipe of lead ownership is intended, and it has to land at 00:00 so the calling day starts clean. So unlike the other three, this one is genuine scheduled work — you cannot make a wall-clock event happen without something that knows the wall clock.

What you *can* remove is the in-process `@Cron`, and the reason to is that it is the least reliable way to run it. Today: every container runs it, so N concurrent `updateMany`s contend over the whole `UserLead` table at 00:00; it is called twice, unawaited at [`tasks.service.ts:44`](../src/tasks/tasks.service.ts) and awaited at [`tasks.service.ts:72`](../src/tasks/tasks.service.ts); the awaited call sits *after* the exchange-rate fetch, which `throw`s on any upstream error, so **an exchangerate-api outage at midnight skips it** and leaves only the unawaited call, whose rejection nobody handles; and if it does not run, leads stay assigned to yesterday's employees all day with no error, no alert and no record.

One of those resolves itself this pass: removing (c) takes the throwing HTTP call out of the method, so an exchangerate-api outage can no longer skip the reset. The duplicate call should be collapsed to a single awaited one at the same time — the unawaited call at [`tasks.service.ts:44`](../src/tasks/tasks.service.ts) is plainly a bug, and it is in the lines being edited anyway.

**The design: make the reset idempotent and date-guarded, then the trigger stops being a correctness problem.**

```ts
// inside resetLeads()
const key = `leads_reset_${istDateStamp()}`;               // YYYY-MM-DD, IST
const acquired = await redisClient.set(key, 1, { NX: true, EX: 172800 });
if (!acquired) return;                                     // already done today
// ...existing updateMany calls
```

`SET NX` is atomic, so N containers racing at 00:00 produce exactly one wipe — that alone fixes the contention. And because the operation is now safe to call any number of times from anywhere, it can be triggered from two places at once:

- **Lazily, on the lead-distribution path.** The first request for leads after IST midnight performs the reset. One `SET NX` per lead request is negligible, and it guarantees the wipe happens before any lead is handed out — which is the actual business requirement.
- **From an external scheduler** (k8s CronJob, systemd timer, cloud scheduler) calling an internal endpoint at 00:00 IST. This is what gives you *exactly* midnight for reporting, and it brings retries, logs and alerting that the in-process cron never had.

**Do both.** The guard means a scheduler that fires late, twice, or not at all cannot break anything, because the lazy path catches it. That inverts today's failure mode: instead of silently running a stale day, the worst case is the wipe landing at the first lead request instead of 00:00.

The endpoint is close to free, because the operation already exists as one. `dissolveLeads` ([`lead.service.ts:13051`](../src/lead/lead.service.ts)) does precisely this — flip `isDone: null → false`, then null `employeeId` — scoped to one employee, behind a `canViewLeads` permission check. The nightly job is the same operation with no employee filter.

**Two things to decide while we are in here**

- **Booked appointments.** `dissolveLeads` deliberately excludes leads with an `appointmentTime`; `resetLeads` ([`lead.service.ts:41`](../src/lead/lead.service.ts)) does not, so the nightly job drops the assignment on a lead that has an appointment booked. One of the two is wrong. If the `dissolveLeads` exclusion is the correct rule, the nightly reset should adopt it.
- **In-flight assignments.** The wipe is unconditional — it also drops a lead an employee picked up five minutes before midnight, mid-follow-up. Worth confirming that is intended rather than incidental.

**One note on the `isDone` half.** It is *not* redundant, but it only matters for some paths. The distribution queries compute their own IST window per request and filter interactions by `createdAt > istMidnight` ([`lead.service.ts:198`](../src/lead/lead.service.ts), [`:592`](../src/lead/lead.service.ts), [`:1082`](../src/lead/lead.service.ts), [`:1527`](../src/lead/lead.service.ts), [`:3663`](../src/lead/lead.service.ts)) — but those windows are −1, −2 and −3 days depending on the path. On the −1 window yesterday's pending interactions are already excluded by date and the flip changes nothing; on the −2 and −3 windows they would still block the lead, and the flip is what unblocks it. So it stays. Separately, `getLeadStats` ([`platform.service.ts:7841`](../src/platform/platform.service.ts)) counts `!lead.isDone` as "skipped", which is true for `null` and `false` alike, so the flip does not move that report either way.

---

### 2. `handleScheduleCallNotification` — every 30 minutes ([line 102](../src/tasks/tasks.service.ts))

**What it does**
Looks for booked calls happening exactly 30 minutes from now and sends the customer a WhatsApp reminder. It compares times down to the millisecond, so it almost never matches a row — this reminder has most likely never been sent.

**Context**

Confirmed by the team:

- **The reminder is still wanted, and 30 minutes before the call is still the right moment.** Both were re-confirmed rather than assumed, because of the point below.
- **A rebooking must not leave the old reminder armed.** Sending it costs money for a message that is also wrong — it tells the customer to be somewhere at a time that no longer applies.

And one thing the code says rather than the team:

- **This has almost certainly never sent a message**, so removing the cron loses nothing and enabling the replacement is a *first* send rather than a like-for-like port. The two are therefore separate steps, and the second is a business decision with a flag in front of it.

**Solution**

**Agreed: one BullMQ delayed job per booking, due at `appointmentTime − 30 minutes`, cancelled when the same person books again, and recorded per recipient in `MessageSend`.**

---

### Why the cron never fired

Worth writing down, because it is not the obvious kind of bug:

```
now      = new Date()          // 10:30:00.412 — whatever millisecond it fired on
minTime  = now + 30 minutes    // 11:00:00.412
find UserContactForm where appointmentTime EQUALS minTime
```

Appointments are stored on the hour with zeroed milliseconds — `postContactForm` does `setHours(hour, 0, 0, 0)` ([`platform.service.ts:8701`](../src/platform/platform.service.ts)) — while `now` carries the millisecond the scheduler happened to wake on. The half-hour grid actually lines up; the milliseconds never do. So the query matched only if the cron fired at exactly `.000`, which it does not.

This is the one entry in this document where the behaviour being ported does not currently exist.

### Why this is a per-row delayed job, and entry 7 was not

The opposite call to (7), for the opposite reason, and the two together are the whole rule:

|  | (7) `handleDailyTasksAtEightPM` | (2) this entry |
|---|---|---|
| When is it due? | 20:00 — one moment every row in the window shares | `appointmentTime − 30 min` — a different moment per booking |
| Can a single query express that? | Yes. Five hundred jobs firing at 20:00 do collectively what one query does. | No. There is no time of day to sweep at. |
| How many creation call sites? | ~21, and the 22nd would silently drop messages | **One**, and it will stay one |

That last row is what settles it. `UserContactForm.appointmentTime` is written in exactly one place — `postContactForm` ([`platform.service.ts:8725`](../src/platform/platform.service.ts)) — and **never updated afterwards**: there is no reschedule path, no cancel path and no admin edit. So the coupling cost that sank the per-row draft of (7) is not present here.

Because the offset is an exact duration, this feature does **no timezone arithmetic at all** and, unlike (7), does not depend on `TZ`.

### How it works, in plain terms

1. **A customer books a call.** Right where the confirmation WhatsApp already goes out, we also write a note into the queue: *"remind booking 8412 at 10:30."* A call booked less than 30 minutes out gets no note — an immediate "your call is in 30 minutes" is noise, and the confirmation they just received carries the time.
2. **Nothing runs in between.** No timer, no sweep, no polling.
3. **The moment arrives.** Redis hands the note to exactly one worker, so one message goes out however many containers are running. (The cron ran in every container, so if it had worked, three containers would have meant three messages.)
4. **That worker writes the ledger row first, then sends.** One `MessageSend` row — `PENDING`, or `SKIPPED` with the reason — then `sendWhatsappMessageStrict`, then `SENT` with a time or `FAILED` with what Aisensy said.
5. **Afterwards it is on record.** The booking's `MessageSend` row says what happened, including "cancelled, superseded by booking 8460". (removed 2026-10-01 — see "Admin endpoints removed" at the end).

```
booking created ------------------------------> [30 min before the call]
       |                                                    |
   cancel any earlier                            still the latest booking?
   booking's reminder                                       |
                                              write MessageSend row (first)
                                                            |
                                             send -> stamp SENT / FAILED
```

### The rebooking rule

The requirement is "a rebooking must not send the old reminder". The wrinkle is that **nothing in the data distinguishes a rebooking from a second, deliberate booking.** `previousForm` cannot carry it: it is set by a `findFirst` with no ordering, over `email OR phone`, and it also matches contact forms that are not bookings at all.

So the agreed rule is the simple one: **the reminder belongs to a person's most recent booking.** Same person means same email or same phone — the identity rule `postContactForm` already uses. A customer who genuinely wants two calls is reminded about the later one only; that is the accepted trade, and it is a one-line change if it ever turns out to be wrong.

**It is enforced in three places, and that is deliberate** given that the cost of getting it wrong is a charged-for message telling someone the wrong time:

| Where | What it does |
|---|---|
| When the new booking is made | Removes the earlier booking's job, and writes it a `SKIPPED` row saying which booking superseded it |
| When the job fires | Re-checks Postgres for a later booking, and does not send if there is one |
| The ledger itself | A `SKIPPED` row is not `PENDING`, so the send step's claim fails outright |

The second is the one that actually guarantees it. Job removal can fail — a job being processed at that instant is locked — but the fire-time check reads the same Postgres rows the rule is defined on and cannot be raced.

**The repair path has to know the rule too**, or a boot reconcile would quietly re-arm every reminder a rebooking had cancelled. It does.

### Why it can't double-send

- **The job id is derived from the booking** (`call-reminder-f<formId>-m30`), and BullMQ ignores an `add` for an id that already exists — so every container can attempt to schedule and exactly one job results.
- **`UNIQUE(blastId, recipientKey)`** means a booking can have at most one ledger row.
- **`SENT` is terminal.** The claim only picks up `PENDING` or `FAILED`.

### If Redis loses the queue

`appointmentTime` is in Postgres, so which jobs should exist is always recomputable. `reconcile` has two halves, because two different things can be lost: Redis losing its keys loses the *jobs* (rebuilt from `appointmentTime`, skipping superseded bookings), and a worker dying between writing a row and sending it leaves an *outstanding row* (rebuilt from the ledger). Add-only on the first half, for the reason recorded in `quiz-reminder.service.ts` — every container runs it at boot, and a remove-then-add would give one container's remove a window to land between another's. Runs on boot and behind an endpoint. Not a schedule; idempotent repair.

### What this costs at volume

**Per-booking jobs do not spread the load — they burst.** The booking form only offers whole hours (`setHours(hour, 0, 0, 0)`), so every appointment is at `hh:00` and every reminder is therefore due at `hh:30:00.000` exactly. All the reminders for one slot fire at the same instant. What the per-row design bought is *correct timing*, which no sweep could deliver; it did not buy smoother load, and the burst is the thing to size against.

A burst of N drains at `25 × containers` per second (the worker's limiter). The failure mode is not a crash but a late message — "your call is in 30 minutes" arriving when the call is 26 minutes away. Allowing that about five minutes of slack, **one container absorbs roughly 7,500 bookings in a single hourly slot.** Since every booking is a call a human then has to take, the real ceiling is headcount: a hundred agents can hold maybe 100–200 calls an hour, which is about eight seconds of drain.

Two things bite well before the queue does:

- **`UserContactForm` has no indexes at all** — not on `email`, `phone` or `appointmentTime`, all three of which the supersede rule filters on. The cron scanned this table unindexed too, so the scanning is not new; what is new is that one such query now runs while a customer waits for their booking to submit. **Fix pending:** `@@index([email])`, `@@index([phone])`, `@@index([appointmentTime])`, to go with the other blocked migrations rather than separately.
- **Aisensy's real rate limit is unknown.** The 25/second limiter is a courtesy, not a measured ceiling. If theirs is lower, adding containers will not help — jobs retry with backoff and the tail lengthens.

If a burst ever does get large, the knob is the seven database round trips each reminder makes: caching the template per platform, folding the supersede check into the booking read, and merging the write-then-read into an upsert would take it to about four. Not done, because nothing today needs it.

### Bugs fixed in the same change

All in the lines being replaced:

- **The millisecond equality** — the reason it never sent. Gone entirely: a delayed job has no comparison in it.
- **`counrtyCode + phone` with both columns nullable** posted the literal string `"nullnull"` to Aisensy. Now a `SKIPPED` row with the reason.
- **Fire-and-forget send.** `sendWhatsappMessage` subscribes and swallows errors, so `await` returns before the message leaves. `sendWhatsappMessageStrict` (added for entry 7) is used instead.
- **No record of anything.** "Did this customer get their reminder?" had no answer.

Not a bug, and worth noting because entry 7's equivalent lookup *was* one: the template lookup here was already correctly scoped by `platformId`.

### As built

**Status: IMPLEMENTED** on branch `feature/cron-removal`. **The cron is deleted** — safe on its own, because it sends nothing — and the replacement now always runs (`schedule_call_reminders_enabled` has been removed).

New, under `src/schedule-call-reminder/`:

| File | What it is |
|---|---|
| `schedule-call-reminder.constants.ts` | The offset, the ids, the ledger statuses and skip reasons, and the pure helpers (`formatAppointmentDate` ported verbatim, `buildPhone`, `buildName`). No DI, so the wording and the id rules are testable without a queue, a database or a clock. |
| `schedule-call-reminder.service.ts` | `onBookingCreated`, `scheduleForBooking`, `cancelEarlierBookings`, `supersededBy`, `runReminder`, `reconcile`, `getReminderStatus`. The repair path answers the supersede rule once per page and writes with `addBulk`, so a boot reconcile over thousands of bookings is a handful of queries rather than one per booking — the round-trip lesson entry 7 already learned. |
| `schedule-call-reminder.processor.ts` | The worker — one job type, one booking each. |
| `schedule-call-reminder.service.spec.ts` | 30 tests, all passing, including one pinning the repair path to a single supersede query per page. |
| `schedule-call-reminder.module.ts` | Imported by `AppModule`, `PlatformModule` and `CommandModule`. |

Changed:

- **`platform.service.ts`** — one line in `postContactForm`, after the booking has committed. Deliberately *outside* the `NODE_ENV !== 'development'` guard that wraps the confirmation message: scheduling should happen everywhere so the path is exercisable, and it is `sendWhatsappMessageStrict` that declines to send in development. It swallows its own errors and is **not awaited**: BullMQ requires `maxRetriesPerRequest: null`, which makes ioredis hold commands indefinitely while it reconnects rather than failing fast, so awaiting it would let a Redis outage hang a customer's booking rather than merely cost them a reminder. The boot reconcile is the safety net.
- **`command.controller.ts` / `command.service.ts`** — `GET command/schedule-call/:id/reminder` (`canViewScheduleCalls`) and `POST command/schedule-call/reminders/reconcile` (`canEditEmployeeToLeadSources`, matching the other reconcile endpoints) (removed 2026-10-01 — see "Admin endpoints removed" at the end); the boot reconcile still runs.
- **`tasks.service.ts`** — the cron and its now-unused `formatAppointmentDate` deleted, with a comment recording where the behaviour went.
- **Two specs** — a `{}` provider for `ScheduleCallReminderService`, since `PlatformService` and `CommandService` each gained a constructor argument.

**No migration.** `MessageSend` already carries this — a new `category` value, `recipientKey` of `contactform-<id>`, and `campaignName` holding the Aisensy campaign name. It does depend on entry 7's `MessageSend` migration being applied, which is still outstanding.

**Verified**

Type check clean (0 errors). 30 new tests pass. The rest of the suite is unchanged from baseline: the two failures in `src/platform` and `src/command` are identical before and after, checked by stashing.

Not yet verified end to end against a live queue — that needs the `MessageSend` table, which is the blocker below.

### To make it actually send

This now runs unconditionally — `schedule_call_reminders_enabled` has been
removed. What's left is the one real dependency: **apply entry 7's
`MessageSend` migration** (`prisma/migrations/20260902200000_add_message_send`)
as a role with owner rights. Without the table, the first ledger write fails,
so every environment without the migration will see reminders fail rather than
silently not send. Nothing can double-send in the meantime, because the cron
it replaces is already gone and was sending nothing anyway.

### Known limits, accepted deliberately

- **Two deliberate calls by one person collapse to one reminder** — the later one. There is no field that distinguishes that from a rebooking; see "The rebooking rule".
- **A call booked inside 30 minutes gets no reminder at all**, rather than an immediate one.
- **A booking with neither an email nor a phone supersedes nothing and is superseded by nothing**, because there is no way to match the person. It is `SKIPPED` for having no phone regardless.
- **The cancellation is one-way.** Deleting the later booking does not re-arm the earlier one's reminder. No path deletes bookings today.
- **`PlatformService` keeps its own copy of `formatAppointmentDate`** for the confirmation message. Now two copies rather than three; merging them was left out of a change about removing a cron.

---

### 3. `revertAllTempPasswords` — every 5 minutes ([line 153](../src/tasks/tasks.service.ts))

**What it does**
When an employee issues a temporary password, the student's real password is copied into `UserMetaHistory`. This job sweeps that table every 5 minutes and puts the real password back once the temporary one is over 5 minutes old. Because it only checks every 5 minutes, a temp password actually lasts between 5 and 10.

**Context**
Students report problems, and to debug them we need to see what the student sees. There is no "log in as this user" feature, so support changes the student's password temporarily, logs in as them, and then asks the student to change it back. Students often forget to do that — which is the only reason this cron exists. It is the safety net for a manual step nobody reliably performs.

Two constraints on any replacement:

- The command panel runs inside an `.exe`, so there are no dev tools and nothing can be pasted into browser storage by hand. The handoff has to work through the UI itself.
- The button can be visible to every employee; it does not need to be restricted to a small group.

Things the current flow does that we would rather it did not: the student is locked out of their own account for 5–10 minutes; the audit row is deleted on revert, so afterwards there is no record that anyone accessed the account; and calling "get temp password" twice can cause the cron to revert the password while the employee is still using it, because the second call never touches the history row's timestamp.

**Solution**

**Status: IMPLEMENTED** on branch `feature/support-password-redis-ttl` (uncommitted). The two open decisions below were settled as suggested: a **30-minute** window, and a key scoped to `userId` alone. See "As built" at the end of this section, which includes a **required pre-deploy step**.

**Agreed: stop swapping the student's password. Issue a second, temporary password that lives in Redis with a TTL, and accept it at login alongside the real one.** The student's own password is never read or written, so there is nothing to revert and the cron has nothing to sweep. Expiry is enforced by Redis dropping the key, so no scheduled job replaces it.

**How it works**

1. Support clicks "Get temp password" on the student in the CRM.
2. The backend generates a password, writes it to Redis under `support_password_<userId>` as `{ password, employeeId }` with a TTL (the access window), writes an audit row, and returns the password.
3. Support types the student's email and that password into the normal login screen.
4. Login accepts it: on the branch where the password does not match `user.password`, it reads the Redis key and compares before rejecting. One extra Redis GET, only on the mismatch path.
5. The key expires on its own. Nothing runs, nothing reverts, and the student's password worked the whole time.

This is not a new pattern here. `loginOTP` ([`auth.service.ts:2439`](../src/auth/auth.service.ts)) already puts a login credential in Redis with a 15-minute TTL and `login()` reads it back at [`auth.service.ts:1004`](../src/auth/auth.service.ts) to authenticate. This is the same mechanism with a different key. The cache is a single shared `KeyvRedis(process.env.redis)` ([`app.module.ts:64`](../src/app.module.ts)) with no in-memory fallback, so every container sees the same key.

**The second click**

Today, clicking twice is a live bug: `getTempPassword` ([`auth.service.ts:5253`](../src/auth/auth.service.ts)) generates a new password and writes it to `user.password` without touching the history row. `updatedAt` is `@updatedAt` and only moves when the row is written, which it is not — so the cron's clock still runs from the first click, and a password issued at 12:04 is reverted at 12:05 while support is still using it.

Under this design the credential and its expiry are the same Redis `set`, so they cannot drift apart. The agreed policy: **a second click returns the same password and resets the TTL.** Support who lost the popup gets the string they already had, two employees helping the same student both work, and clicking during a long session extends the window — which is correct, because someone is actively working. Every click writes an audit row, not just the first.

**Changes required**

- Rewrite `getTempPassword` ([`auth.service.ts:5237`](../src/auth/auth.service.ts)) to set the Redis key. **`revertTempPassword` is deleted outright, not rewritten** — see "Why there is no revoke" below.
- Roughly five lines in `login()` at [`auth.service.ts:988`](../src/auth/auth.service.ts) to accept the support password.
- Do **not** touch [`user.service.ts:632`](../src/user/user.service.ts) or [`user.service.ts:3305`](../src/user/user.service.ts), which check the current password before a password change. The support password must not be usable to change the student's password.
- Audit rows reuse `UserMetaHistory` with `field: 'supportPasswordIssued'` and are **never deleted**. The table already has `userId`, `employeeId`, `field`, `valueJson`, `createdAt`. Do not store the password itself in the row.
- Delete `revertAllTempPasswords` and drop the `MetaHistory` include at [`command.service.ts:3449`](../src/command/command.service.ts) that the panel currently reads to show "temp password active".

**No migration.** No columns on `User`, no new table, nothing in `prisma/schema.prisma`. The whole change is service-layer.

**One front-end change is required**, and it is the only one: the panel's "revert temp password" button must be removed, because the endpoint behind it is deleted. Everything else is front-end-clean — the panel already shows a password and support already types it into the login screen. Relabelling the remaining button and showing the expiry is worth doing but nothing breaks without it.

**Why there is no revoke**

The original sketch kept a counterpart to `getTempPassword` — "revert becomes revoke". On review it earns nothing and actively misleads, so it is gone.

It earns nothing because the capability it would withdraw is not scarce. The button is available to every employee and `getTempPassword` issues a password for any user on demand, so revoking a credential does not stop the same employee re-issuing one a second later. Nothing was taken away.

It misleads because deleting the key blocks a *further* login but does not end a session already opened with the password — that keeps its 3-day JWT, exactly as under the old swap. Nor could it end one selectively: the session is indistinguishable from the student's own, so terminating it would sign the student out too. A control that reads as "access ended" while access continues is worse than no control.

The one case with any substance is the password string leaking beyond the employee who requested it — pasted into a ticket, caught in a screenshot. Revoking would cut exposure from "up to 30 minutes" to "now". That argues for a shorter TTL, which is one constant, rather than for a button.

If revoke should ever genuinely mean "support is out now", it needs the support login tagged as a support session at the moment the Redis key matches, so it can be terminated independently of the student's. That is the first step of the full impersonation deferred above, and the same work that would give per-action auditing.

**What this fixes**

The student is never locked out; their own password works throughout. The audit row survives instead of being deleted on revert. Clicking twice is harmless. And the real password stops leaking: `user.password` is shipped to third parties in several places — [`payment.service.ts:765`](../src/payment/payment.service.ts) puts `StudentPassword=${user.password}` in a URL to an external system — so today, any of those firing during the temp window sends the _temporary_ password outward and then reverts it, leaving the third party holding a dead credential.

The plaintext credential also never reaches disk. Given passwords in this system are already stored in plaintext, not adding a second permanent plaintext column to every user row is a real gain — the support password is in memory for the length of the window and then gone.

The failure mode inverts, too. Today, if the cron does not run, a student is locked out of their account indefinitely and needs a human to fix it. Here, the worst case is a Redis restart or an eviction dropping the key, and support clicks the button again. Nothing about the student's record was ever modified, so there is no state Redis can lose that harms them.

**What this does not do**

The expiry bounds support's ability to _log in_, not their access. Once logged in they hold a normal session: a 3-day JWT ([`app.module.ts:56`](../src/app.module.ts)) and a refresh token good for 30 days. This is already true today — the cron reverts the password at minute 5, but a session opened at minute 2 keeps working for three days. So the current cron provides essentially no access limiting, and this change loses nothing. Two consequences: the window can be generous (30 minutes costs nothing that 5 minutes was buying), and there is no point offering a revoke — the most it could mean is "cannot log in again", never "is out now".

The resulting session is also indistinguishable from the student's own, so there is no per-action record of what support did and no way to restrict it. And support still inherits `giveUser`'s behaviour in full: on a single-login platform, logging in deletes the student's refresh token and signs them out, and on a device-locked platform (`isDevice`) support may not get in at all. Both are the same as today, so neither is a regression — but this change does not fix them.

Full impersonation — a session token issued directly to support, with nothing to expire and a hook to restrict what can be done — solves all three, and the handoff mechanism for it already exists ([`auth.service.ts:899`](../src/auth/auth.service.ts) builds `/oauth-client?access_token=…&refresh_token=…`). It was deferred because it needs work on the student site and this does not. The two are compatible in this order: nothing here changes the front end, so building impersonation later does not require undoing any of it.

**Open decisions — settled**

- **Window length.** ~~Today's answer is "5 to 10 minutes, by accident".~~ **30 minutes**, as suggested. It bounds the ability to log in, not the session, so a generous window costs nothing a shorter one was buying. One constant (`supportPasswordTtlMs`) to change if it turns out to be wrong.
- **Key scope.** **`support_password_<userId>`, no platform scope.** The swap this replaces wrote `user.password` and so worked on every platform the account touches; keying on `userId` alone preserves that behaviour exactly. Per-platform is tighter but would be a behaviour change, so it was not taken.

---

**As built**

Five files changed, no migration. One front-end change required: remove the panel's "revert temp password" button, whose endpoint is deleted.

- **`auth.service.ts`** — `supportPasswordTtlMs` (30 min) and `supportPasswordKey(userId)` added alongside the rewritten `getTempPassword`. `getTempPassword` now writes `{ password, employeeId }` to `support_password_<userId>` in the shared cache and returns `{ tempPassword, expiresAt, expiresInMinutes }`. The `tempPassword` key is kept deliberately so the existing panel keeps working; `expiresAt` is additive for whenever the panel wants to show the window. A second click reads the key back and returns the same password with the TTL reset, per the agreed policy. Audit rows are written on every click as `field: 'supportPasswordIssued'` with `{ platformId, expiresAt, reissued }` in `valueJson` and never deleted; the password itself is not stored. The audit write is wrapped in try/catch — the credential is already issued and usable, so losing the row must not fail the support request.
- **`auth.service.ts`, `login()`** — on the branch where the supplied password does not match `user.password`, the support key is read and compared before rejecting. One Redis GET, only on the mismatch path. Everything else about login is untouched, so support still inherits `giveUser`'s behaviour in full.
- **`revertTempPassword` deleted**, along with its route at [`command.controller.ts:1689`](../src/command/command.controller.ts) and the `supportPasswordRevoked` audit field. A comment where the method was records why, so nobody adds it back by reflex.
- **`tasks.service.ts`** — `revertAllTempPasswords` and its `@Cron('*/5 * * * *')` deleted.
- **`command.service.ts`** — the `MetaHistory` include that fed the panel's "temp password active" indicator dropped. If that indicator is wanted back, it should be derived from the Redis key rather than a history row, but that is a separate change and nothing breaks without it.

Verified: no new type errors (31 before, 31 after — all pre-existing, from a stale generated Prisma client against the `DiscussionToPlatform.courseId` schema change), and no test regressions (34 failed suites / 58 failed tests / 2297 passed, identical on both sides). Both password-change guards — [`user.service.ts:632`](../src/user/user.service.ts) and [`user.service.ts:3305`](../src/user/user.service.ts) — were left alone and compare against `user.password` only, so the support password cannot be used to change a student's password. `login()` is the only student password check in the codebase; the other comparison sites are employee login, the USB password and reset-confirmation flows.

**Required pre-deploy step — not covered by the original design**

The old flow leaves state behind that nothing will clean up once the cron is gone. Any `UserMetaHistory` row with `field: 'tempPassword'` at deploy time means a student whose `password` column currently holds a *temporary* value, with their real one sitting in that row's `valueText`. With the sweeper deleted, that student is **stuck with the temp password permanently** and cannot log in with their own.

So, before or at deploy:

1. Restore `user.password` from `valueText` for every remaining `field: 'tempPassword'` row.
2. Delete those rows. They hold students' real passwords in plaintext and nothing reads them any more.

The window is small — the old cron reverted within 5–10 minutes, so only a temp password issued immediately before the deploy is affected — but it is not zero, and the failure is silent from the student's side. Deploying outside support hours makes it very unlikely; step 1 makes it impossible.

---

### 4. `handleQuizes` — every 5 seconds, 17,280 times a day ([line 200](../src/tasks/tasks.service.ts))

**What it does**
Four separate jobs in one method: start quizzes whose start time just passed, end quizzes about to finish, send a WhatsApp reminder about 2 hours before a quiz, and auto-submit timed attempts that ran out of time. Each asks "what happened in the last five seconds?", so a single missed run loses that moment permanently and silently.

**Context**

Superseded by [docs/quiz-timing-without-sockets.md](quiz-timing-without-sockets.md), which covers this cron (and `sweepStaleAttemptSessions`, entry 5) in full and is the up-to-date source for its status.

**Solution**

**Status: DONE, 8 September 2026.** `handleQuizes` and its cron are deleted entirely from `src/tasks/tasks.service.ts`. All four original pieces are accounted for:

- `handleEndingQuizes`/`handleExpiredDurationQuizAttempts` — gone since order-of-work step 8 (`src/quiz-alarms/`).
- `handleWhatsappReminders` — gone since the `quiz_whatsapp_reminders_enabled` flag was removed: its replacement (the WhatsApp step in `src/quiz-reminder/`, order-of-work step 6) runs unconditionally now that the `MessageSend` migration is applied.
- `handleStartingQuizes` — gone last, same day. Its `quiz-start` push was migrated onto a BullMQ job (`QuizEndService.runStart`, folded into the existing `quiz-end` queue/service rather than a new one — order-of-work step 10) and dual-ran alongside the cron only briefly before the cron was deleted outright, by request. The `socketsJoin`/`socketsLeave` room reassignment it also did was **not** carried anywhere - it had already been commented out (group-quiz peer presence, its own "counters/evidence gate" still unopened) and goes with the deleted method; recovering it means reading git history at the commit that deleted it, not searching a live call site. `TasksService` no longer depends on `QuizService` (`QuizModule` dropped from `tasks.module.ts`).

`ScheduleModule.forRoot()` stays registered - entry 9 (`job.module.ts`'s own `flushJobViewBuffer` cron) is still live, so `@nestjs/schedule` is not yet uninstallable. See "When everything above is done" at the end of this document.

**Future cleanup, not yet due:** the `quiz-start`/`quiz-end` socket emits this migration restored (`QuizEndService.runStart`/`runEnd`, `QuizAttemptEndService.runEnd`) should be deleted once no platform's frontend depends on those events for the quiz workflow any more - i.e. once the client-side replacement has landed everywhere, not just `LMS_V2`. See docs/quiz-timing-without-sockets.md order-of-work step 10 for the full note.

---

### 5. `sweepStaleAttemptSessions` — every 30 seconds ([line 252](../src/tasks/tasks.service.ts))

**What it does**
A safety net for students taking a quiz over plain HTTP. Closing a tab sends no disconnect signal, so the attempt would sit "live" and keep counting time. This reads a Redis bucket of recently-touched sessions and pauses any nobody has touched in about 90 seconds.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 6. `handleHalfHourlyTasks` — every 15 minutes, despite the name ([line 312](../src/tasks/tasks.service.ts))

**What it does**
Calls `giveScheduleLeads`, which finds leads with an appointment in the next hour that nobody is assigned to, and hands them out to employees who are currently online.

**Context**

The first entry where the job's output is not a message but a **work-allocation decision**, and it has to be made against who is logged in at that instant. A dispatch that fires when nobody is online is worth nothing.

**Solution**

**Agreed: one BullMQ delayed job per lead, due at `appointmentTime − 1 hour`, plus an employee coming online as the retry. The cron is deleted.**

---

### The cadence was doing two jobs

This is the whole of entry 6, and it is what makes it different from every entry before it:

| | What it was | What replaces it |
|---|---|---|
| A **timer** | "this appointment has entered the next hour" | a delayed job per lead, due at `appointmentTime − 1h` |
| A **retry** | four attempts an hour, so a lead nobody could be given at T−60 still went out if somebody logged in at T−40 | an employee joining `online_employee` |

The timer half is entry 2's shape exactly: the due moment is derived per row, which is what `@Cron` cannot express, and the hook cost that sank the per-row draft of entry 7 is absent — `UserLead.appointmentTime` is written in three places and `appointmentEmployeeId` in one.

The retry half is new, and it is deliberately **not** a self-re-enqueueing job. A job that re-arms itself every fifteen minutes is the cron again wearing a queue as a disguise, which is the same objection this document already raises against BullMQ's repeatable jobs. The precise trigger for "nobody was online" is "somebody comes online", and it is an event we already have.

Transient failures are a separate thing and keep BullMQ's `attempts` + backoff. "Nobody eligible is online" is not a failure — it is a correct answer that presence revisits.

### Why a purely event-driven design does not work

Tempting shape: no queue at all, just dispatch when an appointment is written and again when an agent logs in. It fails on the ordinary case — a lead booked at 09:00 for a 15:00 call, agents online all day, nobody logging in in between. No write, no login, no dispatch, and the 14:00 window opens to nothing. A per-lead timer is unavoidable.

### How it works, in plain terms

1. **An appointment is written.** Alongside it goes a note in the queue: *"look at lead 4471 at 14:00."* If the appointment is already inside the hour, it is dispatched on the spot instead.
2. **Nothing runs in between.** No timer, no sweep, no polling.
3. **The moment arrives.** Redis hands the job to exactly one worker, so one dispatch happens however many containers are running.
4. **That worker re-reads Postgres, then claims.** `updateMany` with `employeeId: null` in the WHERE is the claim; only the winner writes the activity and interaction rows and pushes the socket event.
5. **If nobody eligible is online**, it logs and stops. The lead stays claimable and the next agent to log in gets it.
6. **Afterwards it is on record.** The lead's `employeeId` and the job's state in the queue say what happened. (removed 2026-10-01 — see "Admin endpoints removed" at the end).

```
appointment written ---------------------------> [1 hour before it]
       |                                                  |
  inside the hour already?                        re-read Postgres
       |                                                  |
   dispatch now                              still unassigned and open?
                                                          |
                                         claim (conditional update) -> emit
                                                          |
                                            nobody online? leave it for
                                            the next employee who logs in
```

That is the happy path, and it is the design. The section below is the same
thing from the other side — every trigger there is, for somebody who has to run
this rather than agree to it.

### What happens when, after the cron is gone

The cron was one thing on one schedule, and reading `tasks.service.ts` told you
everything about when it ran. The replacement has no schedule at all, so the
equivalent question is *"what makes it run?"* — and the answer is six triggers.
Nothing in this feature does anything unless one of them fires.

| # | When | What runs | What it does |
|---|---|---|---|
| 1 | An agent saves a call-back, or a contact form comes in carrying an appointment | `onAppointmentChanged` — three call sites in `lead.service.ts` | Re-reads the lead. If it has a future appointment, has no employee on it and is not closed, it writes **one delayed job**: *"look at lead 4471 at 14:00."* If the appointment is already inside the next hour, it skips the queue and dispatches on the spot. |
| 2 | One hour before the appointment | the delayed job comes due, and Redis hands it to **one** worker | Re-reads Postgres, checks the lead is still worth dispatching, claims it, tells one employee. Detailed below. |
| 3 | An employee logs in | `onEmployeeOnline` — end of `EmployeeService.login` | The set of people who can take a lead has just grown, so it re-runs placement over every lead whose appointment is already inside the next hour and that nobody has. This is the retry. |
| 4 | Midnight, from the `lead-reset` job | `onLeadsReset` — end of `LeadResetService.runReset` | `resetLeads` has just taken every lead off every agent, including appointments in the 00:00–01:00 window whose job already fired. Those are handed out again. |
| 5 | A container boots | `reconcile` | Rebuilds the jobs the queue should be holding from Postgres, then hands out the open window. Repair, not a schedule — a no-op when nothing is wrong. |
| 6 | An admin asks | `POST command/leads/schedule-dispatch/reconcile` (`GET command/leads/:id/schedule-dispatch` was removed on 2026-10-01) | Answers "what happened to this lead", and runs (5) on demand after a Redis loss. |

**Between those triggers, nothing runs.** No timer, no sweep, no polling, no
table scan. That is the whole point of the change: the old job woke up 96 times
a day in every container and almost always found nothing to do.

#### The dispatch itself, step by step

This is trigger 2, and triggers 3, 4 and 5 all end up in the same place — the
only difference is that they arrive with a page of leads rather than one.

1. **Re-read the lead from Postgres.** The job may have been written days ago,
   so nothing in it is trusted. The lead is dropped here if it has been deleted,
   has lost its appointment, has been rescheduled since (the job carries the
   appointment it was created for), has picked up an employee some other way,
   has been closed, or is outside the window.
2. **Work out who could take it.** Everyone with a live socket in
   `online_employee`, and of those, the ones holding `canViewScheduleCalls`.
3. **Pick one.** If the agent who booked the call-back is online it is theirs
   (`scheduled_lead_self`). Otherwise it goes to the next person in a
   round-robin whose position is a counter in Redis, shared by every container
   (`scheduled_lead`).
4. **Claim it.** `updateMany` with `employeeId: null` still in the WHERE. This
   is the point of no return: exactly one caller anywhere in the cluster can
   win, and only the winner continues.
5. **Write the history and push it.** The `UserLeadActivity` and
   `UserLeadInteraction` rows, then the socket event to that one employee.
6. **If nobody eligible was online**, none of the above happens. It logs and
   stops, the lead keeps `employeeId: null`, and trigger 3 picks it up when
   somebody logs in.

#### A day in the life of one lead

- **09:00** — an agent books a call-back for 15:00. The lead is left unassigned
  and a job is written for 14:00. Nothing else happens for five hours.
- **14:00** — the job fires on whichever container Redis picked. The lead is
  still unassigned and still open, two agents are online, so it goes to one of
  them and appears on their screen.
- **If instead nobody had been online at 14:00** — the job completes having done
  nothing, and the lead sits there. An agent logging in at 14:20 gets it
  immediately, rather than waiting for the next quarter-hour tick.
- **If the agent had moved the call to 16:00 at 13:00** — a second job is written
  for 15:00. The 14:00 job still fires, sees the appointment no longer matches
  the one it was created for, and stops.

#### What an operator needs to know

- **It always runs.** `schedule_lead_dispatch_enabled` has been removed —
  there is no longer a request-path way to turn dispatch off short of a
  redeploy.
- **The queue lives on the shared `redis` instance.** Safe while that instance
  keeps `appendonly yes` and no `maxmemory` limit; a memory limit with an
  `allkeys-*` policy would let jobs be dropped silently. See "One Redis, not
  two" above.
- **After a Redis loss, `POST command/leads/schedule-dispatch/reconcile`.**
  Postgres is the source of truth; the endpoint recomputes every job that
  should exist. It is safe to run at any time and as often as you like.
- **To ask what happened to one lead**, `GET command/leads/:id/schedule-dispatch`
  was the answer until it was removed on 2026-10-01. It reported whether a job is armed, when it is due, who ended up with the
  lead, and which rule is holding it back if none of that is true. The cron
  could not answer any of this.

### No migration, no ledger

There is nothing to record. `UserLead.employeeId` plus the `UserLeadActivity` / `UserLeadInteraction` rows this writes already **are** the record of what was dispatched to whom, so unlike entries 2 and 7 this does not wait on `MessageSend`.

`schedule_lead_dispatch_enabled` no longer exists. It used to default **ON**
and only an explicit `'false'` turned it off — an escape hatch for ops, not a
rollout gate, because the cron this replaces was live and doing real work and
a flag defaulting to off would have been an outage. That escape hatch is gone
now; dispatch always runs.

### Bugs fixed in the same change

All in the lines being replaced:

- **Nobody online meant leads assigned to offline people, permanently.** The eligible-employee query built its id filter as a conditional spread ([`lead.service.ts:3388`](../src/lead/lead.service.ts) as it was), so an empty online list did not mean "nobody" — it made the filter vanish and returned *every* employee holding `canViewScheduleCalls`. The lead was assigned to somebody offline, the event went into an empty room, and because the lead then had an `employeeId` it never matched the sweep again. This is the worst of them: it turned "nobody online" into silently lost work.
- **The same bug via `undefined`.** A connected-but-not-logged-in socket has no `employeeId`; the guard tested only whether the *first* element of the array was defined.
- **N containers, N dispatchers.** The cron ran everywhere with no lock, so two containers could both write history for one lead and push it to two different agents. BullMQ gives the job to one worker, and the conditional claim covers the drain paths that are not jobs.
- **Write-before-claim.** The activity and interaction rows were created *before* the lead was updated, so a lost race still left them behind.
- **The rotation restarted at zero** every run and again between the two passes, systematically favouring whichever employee sorted first. It is now a shared `INCR` in the queue's Redis — which is not a nicety here but load-bearing, since each job sees exactly one lead and a per-process counter would send every scheduled lead to the same person.

### Deliberately different, and signed off as such

**When nobody eligible is online the lead stays claimable.** That is what the cron *intended*; it is not what it did (see the first bug above). Anyone who came to rely on offline agents accumulating leads will see a change.

### Two paths that unassign a lead mid-window

A per-lead job has fired and gone by the time these run, so they need their own answer:

- **The nightly reset** (`LeadResetService.runReset`, formerly `resetLeads()` inside `handleRefreshToken`) nulls every `employeeId`. Appointments in the 00:00–01:00 window would be stranded. It now calls the dispatcher's open-window drain directly.
- **`bulkAssignLeadSource`** can null `employeeId` over an arbitrary filter. Admin-initiated and rare; the reconcile endpoint covers it.

(`dissolveLeads` only touches leads with `appointmentTime: null`, so it is unaffected.)

### What this costs at 100K leads

`UserLead` had **no indexes at all** — 62 `@@index` declarations elsewhere in the schema, none on this model. The cron's two `findMany` calls filtered entirely on unindexed columns, which is two sequential scans of the whole table, four times an hour, in every container: roughly 192N full scans a day to answer "nothing to do" almost every time.

After the change the steady-state background cost is **zero**. There is one paged range query per container boot and one per employee login, and per dispatched lead a primary-key lookup, a conditional update and two inserts.

Two things could have regressed and are handled:

- **Presence reads go from one per sweep to one per lead.** `fetchSockets()` is a cluster-wide broadcast every container answers, so a burst of appointments on one slot would turn one broadcast into fifty. The eligible set is memoised in-process for five seconds, which collapses a burst to one read — and is *fresher* than the cron, which took one snapshot at the top of a run and used it for the whole run.
- **Include queries go from ~7 per sweep to ~7 per lead.** Prisma resolves relations one query per level rather than per row. Every one is a PK or FK point lookup, so even a fifty-lead burst costs less than a single cron tick's two 100K scans.

**The index** — `@@index([employeeId, appointmentTime])`, `employeeId` first because it is the equality term (`IS NULL`, which a btree indexes) and `appointmentTime` second as the range. Written as `prisma/migrations/20260903120000_user_lead_dispatch_index`, not `CONCURRENTLY`: Postgres refuses that inside a transaction block and Prisma sends a migration file over the simple query protocol, which wraps it in one — so the concurrent form is a deploy that fails rather than a deploy that is gentler. It is **not a blocker**: the design is already cheaper than the cron with no index at all, because it deletes the daily scans; the index makes the boot and login paths free.

### If Redis loses the queue

`appointmentTime` is in Postgres, so which jobs should exist is always recomputable. `reconcile` has two halves that partition the future: `armFutureAppointments` re-adds jobs for appointments strictly beyond the window (add-only, paged, `addBulk`), and `drainOpenWindow` dispatches anything already inside it directly rather than queueing a zero-delay job. That second half is also what makes a re-add after `resetLeads` work — BullMQ ignores an add for an id it still remembers, including a completed one, so re-arming a job that has already fired would silently do nothing.

Add-only on the first half for the reason recorded in `quiz-reminder.service.ts`. Runs on boot and behind an endpoint. Not a schedule; idempotent repair.

### As built

**Status: IMPLEMENTED** on branch `feature/cron-removal`, and it **always runs** — this is a live replacement, not a gated first send.

New, under `src/lead-assignment/`:

| File | What it is |
|---|---|
| `schedule-lead-dispatch.constants.ts` | The window, the ids, the closed-status list, the rotation key and the presence TTL. No DI, so the id rules are testable without a queue, a database or a clock. |
| `schedule-lead-dispatch.service.ts` | `onAppointmentChanged`, `onEmployeeOnline`, `onLeadsReset`, `dispatchLead`, `drainOpenWindow`, `reconcile`. (`getDispatchStatus` was removed on 2026-10-01.) |
| `schedule-lead-dispatch.processor.ts` | The worker — one job type, one lead each. No limiter: nothing here talks to a third party. |
| `schedule-lead-dispatch.service.spec.ts` | 43 tests, all passing, including one pinning each of the two bugs above. |
| `lead-assignment.module.ts` | Shared with entry 1d since the merge below — it registers both queues and both services. Imported by `AppModule`, `LeadModule`, `EmployeeModule` and `CommandModule`. It does not import `LeadModule`, so there is no cycle. |

Changed:

- **`lead.service.ts`** — `giveScheduleLeads` and `giveScheduleLeadsInternal` deleted (216 lines), with a comment recording where the behaviour went. Three `onAppointmentChanged` call sites, none awaited and each swallowing its own errors, for the reason recorded at `postContactForm` in entry 2. `resetLeads` calls `onLeadsReset`.
- **`employee.service.ts`** — `onEmployeeOnline` after the login emits, not awaited.
- **`tasks.service.ts`** — the cron deleted, with a comment recording where the behaviour went.
- **`command.controller.ts` / `command.service.ts`** — `GET command/leads/:id/schedule-dispatch` (`canViewScheduleCalls`, removed 2026-10-01) and `POST command/leads/schedule-dispatch/reconcile` (`canEditEmployeeToLeadSources`, matching the other reconcile endpoints).
- **`prisma/schema.prisma`** — the index above, with its migration.
- **Five specs** — a `{}` provider or fifth constructor argument, since `LeadService`, `EmployeeService` and `CommandService` each gained one.

**Verified**

Type check clean (0 errors). 43 new tests pass. The rest of the suite is byte-identical to the pre-change baseline: 31 suites failed before and the same 31 fail after.

### Known limits, accepted deliberately

- **An appointment employee who is offline at the moment the job fires loses the lead to the pool**, and does not get it back if they log in a minute later. That is the cron's behaviour; a grace period before releasing to the pool is a one-line change if the team wants one.
- **`bulkAssignLeadSource` unassigning a lead mid-window** is only picked up by the next login or a reconcile.
- **The drain is capped at 200 leads per trigger.** Whatever it does not reach is still held by its own delayed job and by the next login.
- **The 5-second presence memo** means a dispatch can pick an employee who logged out in the last five seconds. The lead is then assigned but not pushed; it reappears through `giveScheduledCalls` on their next request, exactly as it would have under the cron's per-run snapshot.

### Review findings — recorded, not implemented

A read-through of the branch on 2026-09-03. The approach above was confirmed as
right: the split of the cadence into a timer and a retry, the derived job id
that makes reschedule-cancellation unnecessary, the fire-time re-read against
Postgres, and claim-before-write are all the correct shape, and the coverage
against the two passes of the old `giveScheduleLeads` checks out. What follows
is what the read-through turned up. **None of it is fixed on this branch.**

Independently re-verified while reviewing: type check clean, the 43 new tests
pass, and the two suites that fail in the touched set
(`lead.converted-followup.spec.ts`, `employee.gateway.spec.ts`) fail on
`FileLoggerService` at index [3] and `DeviceService` at index [1] — both
predate this work, which supports the byte-identical-baseline claim above.

**Two that are worth fixing before this is called finished**

- **`drainOpenWindow` breaks its loop too eagerly** ([`schedule-lead-dispatch.service.ts:604`](../src/lead-assignment/schedule-lead-dispatch.service.ts)). `placeLead` returns `NOBODY_ONLINE` only when the lead is *not* self-placeable **and** the pool is empty — and `onlineIds` and `pool` are different sets, because an employee can be online without `canViewScheduleCalls`. In that state the first lead with no owner online breaks the loop, skipping a later lead in the same page whose own `appointmentEmployeeId` *is* online and which would have gone out as `scheduled_lead_self`. The cron placed those. The comment at that line ("the pool is empty for everybody, not just this lead") is true of the pool but not of the self path. `continue` costs nothing — `placeLead` returns before `nextInRotation` when the pool is empty — so the `break` is a false optimisation that loses leads. The test at `schedule-lead-dispatch.service.spec.ts:718` does not catch it: it passes `online: []`, which returns at the earlier `if (!targets.onlineIds.size) return 0`.

- **`onLeadsReset` should call `reconcile()`, not `drainOpenWindow()`** ([`schedule-lead-dispatch.service.ts:202`](../src/lead-assignment/schedule-lead-dispatch.service.ts)). `resetLeads` unassigns across the whole table; the drain only re-places the next hour. That is enough **provided a job was already armed**, and there is one reachable path where it was not: the update branch of `createLeadFromContactForm` ([`lead.service.ts:6429`](../src/lead/lead.service.ts)) writes `appointmentTime` without touching `employeeId`, so if the lead is currently owned by an agent, `isSchedulable` is false and no job is written. Midnight then unassigns it, and a lead with a three-days-out appointment is left with no owner and no job. The drain cannot reach it; only a container boot happens to. Under the cron it would have been swept at T−1h. `reconcile()` is exactly the tool for this — `armFutureAppointments` is add-only, paged and idempotent, so the cost when nothing is wrong is one indexed range scan. The same one-line change closes **`bulkAssignLeadSource`** ([`lead.service.ts:13857`](../src/lead/lead.service.ts)), listed under the known limits above.

**Smaller, none of them load-bearing**

- **`armed` is not a useful number.** `armFutureAppointments` counts jobs *sent*, and BullMQ silently ignores an id it already holds, so a healthy reconcile reports the entire future backlog as "armed". That is the one figure an operator reads to decide whether a repair actually did anything.
- **`armFutureAppointments` has no total ceiling.** `PAGE_SIZE` bounds memory per page, not the number of pages, and every container walks the whole future set on boot. Fine at current volume; a bad import would make every deploy expensive.
- **An inverted comment on an admin-facing field** ([`schedule-lead-dispatch.service.ts:747`](../src/lead-assignment/schedule-lead-dispatch.service.ts)): "Null means it should not be dispatched at all right now" — `reasonNotToDispatch` returns null when the lead *should* go out. Relatedly, a perfectly healthy armed lead reports `blockedBy: "the appointment is not inside the dispatch window yet"`, which reads like a fault to whoever is looking.
- **`nextInRotation` burns a slot on `LOST_RACE`** — the counter is incremented before the claim is attempted. Bounded and mod-uniform, so harmless; noted only because concurrent logins each run a full drain, which wastes most of those increments.

**Ops, not code**

- `20260903120000_user_lead_dispatch_index` sorts after `20260902200000_add_message_send`, so `migrate deploy` applies `MessageSend` first. Not wrong, but shipping this index also lands the migration that entries 2 and 7 are gated on — worth deciding deliberately rather than discovering. Neither will apply under the `suraj` role.
- `formatted.json`, `sample.json` and `to_format.json` are untracked in the working tree and unrelated to this work. They should not go into the commit.

### The two lead modules were merged

`src/lead-reset/` (entry 1d) and `src/schedule-lead-dispatch/` (this entry) are now one module, [`src/lead-assignment/`](../src/lead-assignment/) — `LeadAssignmentModule`.

**Why these two and no others.** They are the only pair of cron replacements whose subject entity is the same: both write `UserLead` and `UserLeadInteraction`, and between them they answer one question — who owns this lead right now. The reset mass-unassigns at 00:00 IST; the dispatch assigns an hour before an appointment. The code already said so: `LeadResetModule` imported `ScheduleLeadDispatchModule` because the wipe's last act is `ScheduleLeadDispatchService.onLeadsReset()`. The merge deletes that edge from the module graph rather than relocating it.

The other three replacements stay where they are. `src/whatsapp-reminder/` reads `UserLead` but as a *cohort source*, not a subject — its actual subject is a 20:00 window spanning two unrelated entities, and pulling its lead half in here would recreate the `LeadModule -> WhatsappReminderModule -> WhatsappModule -> LeadModule` cycle that the cohort design removed (see entry 7). `src/schedule-call-reminder/` owns `UserContactForm`, and `src/quiz-reminder/` owns `Quiz`. What the two WhatsApp modules share is a delivery mechanism — `MessageSend`, `PlatformTemplate`, `WhatsappModule` — not an entity, and the answer to a shared mechanism is a shared provider, not a merged module. Worth its own ticket once the `MessageSend` migration lands and both are actually running.

**What did not change.** A pure move: no logic edits, no merged processors, no consolidated services. Two services, two queues, two `@Processor`s, two spec files. The queue name strings `lead-reset` and `schedule-lead-dispatch` are byte-identical — renaming one would orphan the delayed jobs already sitting in Redis — as were, at the time of this merge, both env flags (both since removed, see "The four flags — removed") and all four routes, which are unchanged today (`POST command/lead-reset/run`, `GET command/lead-reset/status`, `GET command/leads/:id/schedule-dispatch`, `POST command/leads/schedule-dispatch/reconcile`). Filenames kept their `lead-reset.*` and `schedule-lead-dispatch.*` prefixes for the same reason: each matches its queue constant, and renaming them would split the filename from strings that cannot move.

**One side effect worth knowing.** `EmployeeModule` imported `ScheduleLeadDispatchModule` and now imports `LeadAssignmentModule`, so `LeadResetService` is resolvable from its injector. Nothing in `EmployeeModule` injects it; this is graph noise, not behaviour.

**Verified.** `tsc --noEmit` 0 errors and `nest build` clean, both matching the pre-move baseline. `npx jest src/lead-assignment src/command src/employee src/lead`: 3 failed suites / 5 failed tests / 379 passed / 384 total, identical to baseline — the three failures (`chat-admin.service.spec.ts`, `employee.gateway.spec.ts`, `lead.converted-followup.spec.ts`) are pre-existing and untouched by this work.

---

### 7. `handleDailyTasksAtEightPM` — daily at 20:00 ([line 270](../src/tasks/tasks.service.ts))

**What it does**
Two unrelated WhatsApp batches: chasing up "New Enquiry" leads from the last day that nobody called, and checking in with students who enrolled exactly 30 days ago. Both send one message at a time, inside the process serving live users, with no record of what went out.

**Context**

Confirmed by the team:

- **20:00 is the end of the calling day, not an arbitrary hour.** The lead nudge means *"the team had until the end of today to call you, and nobody did."* So the moment it is due is **the first 20:00 IST after the lead arrives** — a lead at 09:00 is nudged the same evening, a lead at 21:00 is nudged the next. Not a fixed duration after arrival: a lead that comes in at 21:00 has had no calling day at all yet.
- **"Nobody called" is `LeadStatus.name = 'New Enquiry'` and `action = 'Call'`.** This is not a proxy the cron invented — it is the codebase's own definition of an untouched lead. The employee dashboard counts exactly that pair as `pendingLeads` and everything else as `touchedLeads` ([`lead.service.ts:9919`](../src/lead/lead.service.ts), and again at 10534 and 11189).
- **The 30-day check-in stays scoped to platform 1, and its eligibility query is ported verbatim** — including the five levels of nested `Course.OR`. Deliberate: what that query *selects* is a separate decision from removing the cron, and settling both at once would make it impossible to tell a behaviour change from a regression. It is written down as a known limit below rather than fixed here.
- **Knowing what went out is a requirement**, the same as entry 8. Per batch and per recipient we must be able to say who was messaged, who was not, and why. Today nothing records this.

**Solution**

**Agreed: one 20:00 trigger called from outside the app, two cohort queries, and one `MessageSend` row per recipient — then BullMQ delivers the messages one recipient at a time.**

### The workflow, in plain terms

Think of it as four steps.

**1. Something outside the app knocks on the door at 20:00.**
Today the app wakes itself up with a `@Cron`, and it does that in *every* running container — which is why three containers meant every person got three WhatsApp messages. Instead, a scheduler outside the app calls one URL: `POST command/whatsapp-reminders/run`. One knock, one run, no matter how many containers are running.

**2. The app asks two questions.**
- *"Which leads came in since 20:00 yesterday that nobody has called?"*
- *"Who enrolled in a course about 30 days ago?"*

These are the same two questions the cron asked. The difference is that the app now asks them **as of 20:00 exactly**, rather than "as of whenever I happened to wake up". That sounds like a detail, but it is what makes the run repeatable: ask the same question about the same evening and you get the same list.

**3. It writes down who is owed a message — before sending anything.**
One row per person in a table called `MessageSend`, each marked either *"still to send"* or *"skipped, because …"* (no phone number, no template for their brand). Writing this down first is the important bit: if the app crashes halfway through, we still know exactly who was owed what. The old cron kept no record at all, so "did Priya get her follow-up?" was unanswerable.

**4. BullMQ sends them, one person at a time.**
Each row becomes a small job. A job goes to exactly one worker, sends one WhatsApp message, then stamps its own row *sent* (with the time) or *failed* (with the reason). If Aisensy is down, that one job retries on its own and the rest carry on.

### Why this can't double-send

Two safeguards, and neither depends on anyone being careful:

- **Each evening has a name** — `wa-leadnudge-2026-09-02`. The database refuses a second row for the same person under the same name. So running the same evening twice adds nobody twice.
- **"Sent" is final.** Nothing ever moves a row out of *sent*, and the send step only picks up rows that are *still to send* or *failed*.

Together those mean re-running is boring, which is the point: **if an evening gets missed, you just run it again** with `?date=2026-09-02`. Under the old cron a missed evening was gone for good, because its window slid along with the clock.

### What you can ask afterwards

| Question | Where |
|---|---|
| What happened to this lead's follow-up? | `GET command/lead/:id/nudge` |
| Redis lost the queue — resend what's outstanding | Restart or redeploy: the boot reconcile re-enqueues every PENDING row |
| Some sends FAILED — retry them | Re-run that window: `POST command/whatsapp-reminders/run?date=YYYY-MM-DD` |

`GET command/whatsapp-reminders/window`, `GET command/enrollment/:id/checkin` and `POST command/whatsapp-reminders/reconcile` were removed on 2026-10-01 (see "Admin endpoints removed" at the end).

---

Same ledger idea as entry 8 — see "Shared infrastructure: the job queue" at the top of this document for the queue and its Redis requirements, and [`src/quiz-reminder/`](../src/quiz-reminder/) for the pattern the send step follows.

---

**How it works** — one trigger, two cohort queries, then one send job per recipient.

1. **An external scheduler calls `POST command/whatsapp-reminders/run` at 20:00 IST.** Not an in-process `@Cron`: the goal is no scheduled jobs in this project, and a cron registered in every container is exactly why every message went out N times.
2. **Each batch runs its cohort query** — the cron's own `where` clauses, with `now` pinned to the window instead of "whenever the container happened to fire".
3. **One `MessageSend` row per recipient is written before anything is sent**, each already marked `PENDING` or `SKIPPED` with a reason.
4. **One BullMQ job per `PENDING` row.** Redis hands each to exactly one worker, so each recipient is messaged once however many containers are running.
5. **Each job sends and stamps its own row** `SENT` with a time, or `FAILED` with the reason from Aisensy.
6. **Afterwards it is queryable.** `GET command/lead/:id/nudge` answers who got what, and why not.

```
scheduler 20:00 --> POST whatsapp-reminders/run
                             |
              +--------------+--------------+
              |                             |
      lead nudge cohort            30-day check-in cohort
              |                             |
     MessageSend rows (PENDING/SKIPPED, written first)
              |
     one BullMQ job per PENDING row
              |
     send -> stamp SENT / FAILED
```

### Why not per-row delayed jobs

**An earlier draft of this entry did exactly that, and it was wrong.** It gave every lead and every enrolment its own delayed job, scheduled from ~21 creation call sites. Recorded here because the mistake is an easy one to repeat.

A delayed job earns its keep when the due moment is derived per row and lands at an arbitrary time — entry 8's case, where a quiz starting at 09:00 needs its email at 09:00 the previous day and no nightly sweep can express that. **Confirming 20:00 as a real requirement is what took entry 7 out of that category:** every row in a 24-hour window then shares one due moment, so five hundred per-row jobs firing at 20:00 do collectively what one query does — while coupling the feature to every place a lead or an enrolment is created, where the 22nd such place silently drops messages.

Note the doc's own framing above grouped (7) with the delayed-job entries via *"is the same 'send a batch and record what went out'"*. That kinship is the **ledger**, not the timing. The genuinely per-row entries are (10), (4) and (2).

BullMQ still does real work here — per-recipient retry, backoff, rate limiting, and exactly-once delivery via derived job ids. It is just not asked to hold a clock it does not need to hold.

### The windows

| Batch | blastId | Cohort |
|---|---|---|
| Uncalled lead nudge | `wa-leadnudge-<YYYY-MM-DD>` | `UserLead.createdAt` in `[window − 24h, window)` — the cron's `[now − 1 day, now)` |
| 30-day course check-in | `wa-course30-<YYYY-MM-DD>` | `UserToCourse.createdAt` in `[window − 30d, window − 29d)` — the cron's own slice |

**Pinning `now` to the window is the whole trick.** The cron's ranges moved with the clock, so a run at 20:04 covered a different set than one at 20:00 and no run was reproducible. Pinned to 20:00, consecutive windows tile exactly — yesterday's `lt` is today's `gte` — so re-running a window is deterministic and catching up a missed evening is just running it with `?date=`.

**One blastId per batch per window is what makes it idempotent.** `UNIQUE(blastId, recipientKey)` then means a recipient can have at most one row per window, so a retry, a catch-up, or two schedulers firing at once cannot produce a second message. The send job ids are derived from the row id, so a re-run cannot enqueue a second send either.

| Requirement | What makes it true |
|---|---|
| One message per person, not one per container | One HTTP call runs the batch, and BullMQ hands each send to exactly one worker. The cron ran in every container, so N containers meant N copies of every message. |
| A lead called before the nudge is due is not nudged | The cohort query filters `LeadStatus.name = 'New Enquiry'` at run time. **Parity with the cron**, which filtered the same way — not a fix. |
| Nobody is messaged twice | `SENT` is terminal, and `UNIQUE(blastId, recipientKey)` blocks a second row for the same recipient in the same window. |
| A missed evening is recoverable | Re-run it: `POST command/whatsapp-reminders/run?date=YYYY-MM-DD`. The cron's window moved with the clock, so a missed evening was simply lost. |
| The right brand's template goes out | The lookup is scoped by `platformId`, once per platform in the cohort. `PlatformTemplate` has that column and both cron lookups ignored it, so today it returns whichever platform's row has the lowest id — and the lookup sat *inside* the per-lead loop. |
| One batch failing does not take the other down | They are settled independently. The cron put both in one method with no `try`/`catch`, so batch A throwing killed batch B. |
| We can say who was and was not messaged | One `MessageSend` row per recipient per window, including `SKIPPED` rows with a reason. |

**Eligibility is evaluated at run time**, including the five-level platform walk, which is when the cron evaluated it too.

---

**Two supporting fixes this needs**

- **`sendWhatsappMessageStrict`.** [`whatsapp.service.ts:15`](../src/whatsapp/whatsapp.service.ts) never awaits the HTTP post — it `subscribe`s and swallows errors into `console.error` — so the `await` at the call site returns before the message leaves and the ledger would stamp `SENT` for a message that failed. Added alongside rather than replacing it: the fire-and-forget variant has ~90 call sites whose behaviour on an outage would change from "log and carry on" to "throw".
- **Phone and name construction.** `lead.countryCode + lead.phone` with both columns nullable sends the literal string `"nullnull"` to Aisensy ([lines 296](../src/tasks/tasks.service.ts) and 389), and `fname + ' ' + lname` renders `"Raj null"`. A missing phone becomes a `SKIPPED` row with the reason; the display name joins on the parts that exist.

---

**The one place wall-clock time appears**

Entry 8 has no timezone arithmetic anywhere, because its offsets are exact durations. "20:00" is not — it is a wall-clock time in a specific zone, and it has to be 20:00 IST.

The process already runs in that zone: `TZ='Asia/Kolkata'` is set in [`.env`](../.env), so plain `Date` methods give IST and no date library is needed (there is none in [`package.json`](../package.json)). **That makes `TZ` load-bearing for this feature.** `.env` is gitignored, so this has the same per-environment fragility as `redis_queue` above — an environment that boots without `TZ` set computes 20:00 UTC, which is 01:30 IST. The batch asserts the offset and logs an error rather than silently sending at the wrong hour.

**The trigger is the one new operational requirement.** The endpoint sits behind `EmployeeAuthGuard`, so whatever calls it needs a token — that has to be set up per environment alongside the schedule itself, and until it is, nothing runs.

**On the request holding the connection open.** The batch runs inside the POST, so the caller waits for it. That does not block the event loop — every step is awaited I/O (Prisma, Redis), so other requests interleave normally, and there is no CPU-bound work anywhere in the path. What it does mean is that the *request* is as slow as the batch, which was a genuine timeout risk while the enqueue did one Redis round-trip per recipient: a thousand-row evening was a thousand sequential round-trips. It now uses `addBulk`, one pipelined call per 500-row page, so the whole batch is a handful of queries plus two bulk inserts.

Keeping it synchronous is deliberate: the scheduler gets a real result it can alert on, which is the point of a nightly job. If cohorts ever grow past what a request should carry, the escape hatch is to enqueue the batch itself as a job and return `202` with its id — the `MessageSend` rows for that window answer "did it work?" independently (`GET command/whatsapp-reminders/window` read them until it was removed on 2026-10-01). Not done now, because it trades away the failure signal for a problem this volume does not have.

---

**The ledger is a new table, and it should stay one.** Reusing `EmailSend` was considered and rejected: it would mean a phone number in `recipientEmail`, an Aisensy campaign name in `subject`, `templateId` left null because it is `Int?` while WhatsApp templates are identified by string campaign name, and a table called `EmailSend` carrying `category = 'WHATSAPP_…'`. Four repurposed fields and a contradicted table name is the shape not fitting, and it would have been done to dodge a permissions problem rather than for any design reason. The existing event logs are no better a home — `UserLeadHistory` is a field-change log (its keys are `fname`, `email`, `phone`, `lead-status-followup`) and `UserToCourseHistory` is an enrolment-expiry audit; neither is a send ledger.

**Blocker, and it is not specific to this entry.** `MessageSend` needs a migration, and the development `suraj` role cannot create it: `has_schema_privilege('suraj', 'public', 'CREATE')` is `false`, the role is only a member of `growth_rw` (DML), and all 298 tables in `public` are owned by `gc_dev_app`. Note this is a *different* privilege from the one entry 8's unique index hit — that failed on table ownership (`ALTER`), this fails on schema `CREATE` — but both are refused.

More to the point, **nothing applies Prisma migrations in any environment today.** [`deploy.yml`](../.github/workflows/deploy.yml) says so at lines 264-269: the Dockerfile deliberately does not call `npm run build`, so a schema change reaches a box only when someone migrates by hand, and the `migrate` verb that would automate it is itself marked `NOT DONE - blocking`. So every schema change in this project already depends on a human with owner rights. The unblock is one grant —

```sql
GRANT CREATE ON SCHEMA public TO growth_rw;
```

— and it serves every remaining entry in this document, not just this one.

### Status: cron removed, flag removed, still blocked on the migration

`whatsapp_reminders_enabled` has been removed — the replacement now runs
unconditionally whenever `POST command/whatsapp-reminders/run` is called.
**That does not mean it sends today**, because the one real dependency is
still outstanding: every send writes a `MessageSend` row *before* the message
leaves, so with the table absent the batch fails on its first write. The
migration is [`prisma/migrations/20260902200000_add_message_send`](../prisma/migrations/20260902200000_add_message_send/migration.sql)
and needs owner rights on the database. Checked on the development database:
the table does not exist and `_prisma_migrations` has no record of the
migration ever being attempted.

Two things remain, and only one is code:

1. **Apply the migration** as a role with owner rights. Without the table the
   first ledger write fails — in every environment that hasn't applied it, the
   batch will now error rather than sit inertly off.
2. **Point a scheduler at `POST command/whatsapp-reminders/run`** for 20:00
   IST, with an employee token. The module has no timer of its own, on
   purpose — with nothing calling it, nothing ever runs.

**Removing the flag changes the failure mode, not the outcome.** While the
cron was live, running this before the migration risked double-sending; now
that the cron is already gone, running it before the migration just means the
batch throws instead of doing nothing. Neither state is "sending correctly" —
that still needs the migration applied first.

**Catching up afterwards.** Windows are addressable by date, so evenings
missed while the migration was outstanding can be run individually with
`POST command/whatsapp-reminders/run?date=YYYY-MM-DD` once the table exists.
Whether stale nudges should be sent at all is a judgement call — a two-week-old
"nobody called you today" is worse than silence — but the option exists and is
idempotent.

### What landed

| File | What it is |
|---|---|
| [`whatsapp-reminder.constants.ts`](../src/whatsapp-reminder/whatsapp-reminder.constants.ts) | Window arithmetic, cohort ranges, blast ids, statuses, skip reasons. Pure — no DI — which is what makes the window rules testable without a queue, a database or a clock. |
| [`whatsapp-reminder.service.ts`](../src/whatsapp-reminder/whatsapp-reminder.service.ts) | The two batches, the per-recipient send, repair, reporting. |
| [`whatsapp-reminder.processor.ts`](../src/whatsapp-reminder/whatsapp-reminder.processor.ts) | The BullMQ worker — one job type, one recipient each. |
| `MessageSend` in [`schema.prisma`](../prisma/schema.prisma) | The ledger, plus the migration above. |
| `sendWhatsappMessageStrict` in [`whatsapp.service.ts`](../src/whatsapp/whatsapp.service.ts) | The awaiting, throwing sender. |
| 5 endpoints on [`command.controller.ts`](../src/command/command.controller.ts) | `POST whatsapp-reminders/run`, `GET whatsapp-reminders/window`, `GET lead/:id/nudge`, `GET enrollment/:id/checkin`, `POST whatsapp-reminders/reconcile`. The window, check-in and reconcile endpoints were removed on 2026-10-01. |
| 46 tests | Windows and cohort tiling (22), batch and send behaviour (24), asserting one former bug at a time. |

**One module, and the cohort design is why.** The per-row draft needed `LeadModule`, `PlatformModule`, `PaymentModule`, `CommandModule`, `AuthModule` and `ExternalModule` to inject a scheduler, which forced `LeadModule -> WhatsappReminderModule -> WhatsappModule -> LeadModule` and a two-module split to break it. Dropping the ~21 creation hooks dropped the cycle, the split, 6 constructor injections and 4 spec provider mocks with it.

**`reconcile` is repair, not a schedule.** It re-enqueues a send job for every row still `PENDING` or `FAILED` across every window — the answer to a Redis instance that lost its queue, since the ledger is in Postgres and what is outstanding is always recomputable. Idempotent: the job ids are derived from the row, so it is a no-op when nothing is wrong.

### Known limits, accepted deliberately

- The check-in stays hardcoded to `platformId: 1`, one of sixteen places in the codebase that does this.
- Its platform walk stays five levels deep, so a course nested six deep is still silently dropped. Generated from a `PLATFORM_WALK_DEPTH` constant rather than transcribed, so the filter is identical but the depth is named.
- A student enrolled in three courses inside one window still gets three identical check-ins, because `recipientKey` is keyed per enrolment. Faithful to the cron, which looped `userToCourse` rows. Keying it `user-<id>` would dedupe them for free off the same unique constraint — a behaviour change nobody has asked for.
- The lead nudge's delay is still uneven by design: a lead arriving at 19:50 is nudged ten minutes later, one arriving at 20:05 waits nearly a day. That follows from "end of the calling day" and matches the cron exactly.

---

### 8. `sendQuizUpdates` — daily at 23:15 ([line 435](../src/tasks/tasks.service.ts))

**What it does**
Emails students about quizzes coming up in 7 days and in 1 day, one email at a time via Brevo. The pause meant to respect the rate limit is written incorrectly — `sleep()` ([`tasks.service.ts:554`](../src/tasks/tasks.service.ts)) builds a function and never calls it — so it throttles nothing. It would not matter if it did: `sendBrevoMail` ([`email.service.ts:205`](../src/email/email.service.ts)) fires the request without awaiting it, so the `await` in the loop returns before the email is sent, and errors are swallowed into `console.error`.

**Context**

Confirmed by the team:

- **The offsets are exact durations, not calendar days.** "One day before" means 24 hours before `startTime`, and "one week before" means 7 × 24 hours before it. A quiz starting at 09:00 needs its 24-hour email at 09:00 the previous day.
- **Late registrants get only the reminders whose moment has not yet passed.** Register two days before a quiz and you get the 24-hour email and nothing else. Register four days before and you get whichever steps still lie ahead. A reminder whose time has gone is never back-filled.
- **Knowing who received the email is a requirement.** Per quiz and per reminder step, we must be able to say which students were emailed, which were not, and why. Today nothing records this.

**Solution**

**Agreed: adopt BullMQ, hold each reminder as a delayed job, and record every recipient as a row in the existing `EmailSend` table.**

This is the first entry where relocating the trigger is not enough. Every other daily job in this document can be driven by an external scheduler firing once at a fixed time, because the work itself is "do this at 00:00". Here the send time is derived from each quiz's own `startTime`, so it lands at an arbitrary time of day — a nightly sweep cannot deliver "exactly 24 hours before" and neither can an external scheduler running once a night. The clock has to be per-quiz, which is what a delayed job is.

**A note on scope.** BullMQ is adopted for the cron removal as a whole, not for this job alone — see "Shared infrastructure: the job queue" at the top of this document for the queue itself, its Redis requirements and which other entries it serves. This entry is a good first one to prove it on because the volume is low and the failure is visible.

---

**How it works** — the whole flow, for reference. Detail follows in "The shape" and "Tracking" below.

1. **A quiz is created or edited.** For each reminder step we write one note into the queue: *"run the 24-hour reminder for quiz 42 at 09:00 on the 9th."* A step whose moment has already passed is not written.
2. **Nothing runs in between.** No timer, no polling. The note sits in Redis with a due time.
3. **The moment arrives.** Redis hands the note to exactly one server — so exactly one copy of each email goes out, however many containers are running.
4. **That server reads who is registered *at that moment*** and writes one `EmailSend` row per student: *owed this reminder, not sent yet.* This happens **before** any email leaves.
5. **One send task per row.** Each sends a single email, then stamps its own row `SENT` with a time, or `FAILED` with the reason from Brevo.
6. **Afterwards it is queryable.** `GET command/quiz/:id/reminders` answers, per step, who received it and who did not.

```
quiz created/edited                                       quiz starts
       |                                                        |
       |-- note ------------> [168h mark]                       |
       |-- note ---------------------------> [24h mark]         |
                                                 |
                                    who is registered NOW
                                                 |
                             one "not sent yet" row per student
                                                 |
                                send -> stamp SENT / FAILED
```

| Requirement | What makes it true |
|---|---|
| Exactly 24 hours before, not "the night before" | The note carries the actual moment, derived from `startTime`. No timezone maths anywhere. |
| Nobody is emailed twice | `SENT` is terminal — the send step will not touch a row that already says `SENT`. So a retry, a repair or a double click is harmless. |
| Late registrants get only the steps still ahead | Registration is read when the note comes due, not when the student signs up. Nothing tracks per-student state. |
| Editing a quiz moves its reminders | The job ids are derived from the quiz, so the old notes are found and torn up, then rewritten. Deactivating tears up and writes none. |
| A restart or crash loses nothing | The notes are on disk (AOF). Independently, `startTime` lives in Postgres, so which notes *should* exist is always recomputable — that rebuild runs on every boot and is exposed as an endpoint. |
| We can say who was and was not emailed | One `EmailSend` row per student per step, including `SKIPPED` rows with a reason for students who have no email address. |

One thing this depends on per environment, covered above: the shared `redis` instance keeping `appendonly yes` and no `maxmemory` limit ("One Redis, not two"). There is no queue-specific variable to set.

---

**Setup**

Covered once in the shared section above: `bullmq` is the one new package, `ioredis` is already a dependency, and the queue runs on the existing `redis` instance. Delayed jobs, not BullMQ's repeatable jobs.

---

**The shape**

Reminder steps become a list of offsets. Today that is `[168h, 24h]`.

When a quiz's `startTime` is set or changed, add one delayed job per step:

- Job ID is **derived**, not random: `quiz-reminder-q<quizId>-h<offsetHours>`.
- Due at `startTime − offset`.
- Steps already in the past are skipped, not scheduled.

`Quiz.startTime` is only ever written in three places, all admin, all in one file — `adminCreateQuiz` ([`quiz.service.ts:8238`](../src/quiz/quiz.service.ts)), `adminUpdateQuiz` ([`quiz.service.ts:8257`](../src/quiz/quiz.service.ts)) and `adminChangeQuizParent` ([`quiz.service.ts:8295`](../src/quiz/quiz.service.ts), which does not touch the time). So the hook is two call sites.

The derived ID does two things beyond identifying the job. BullMQ ignores an `add` for an ID that already exists, so **every container can attempt to schedule and exactly one job results** — the duplicate-send problem this cron has today (all containers run all crons, so N containers means N copies of every reminder) disappears structurally rather than by convention. And because the ID is recomputable from the quiz, a job can be found and removed without storing a handle anywhere.

**When the job fires, it does two things in this order:**

1. **Write the snapshot.** Read who is registered for the quiz *at that moment* and `createMany` one `PENDING` row per recipient with `skipDuplicates: true`.
2. **Send.** Enqueue one short send job per `PENDING` row. Each one sends via `sendBrevoMailStrict` ([`email.service.ts:235`](../src/email/email.service.ts)) and updates its own row to `SENT` with `sentAt`, or `FAILED` with `errorMessage`.

**The order is the point.** The list of who is owed an email reaches Postgres before a single email is sent, so a worker dying mid-batch, a Redis loss, or a deploy leaves a complete record of what was still outstanding. Retrying is safe in both phases: step 1 re-runs as a no-op under `skipDuplicates`, and step 2 only picks up rows that are not already `SENT`. Nobody receives a second copy.

**Registration needs no hook at all.** The agreed late-registration rule falls out of the firing time: a student registered before the 24-hour job fires is in the snapshot, and one who registers after it is not. There is no per-student bookkeeping, no "has this student already had their 7-day email" flag, and nothing to reconcile between the two.

**One send job per recipient rather than a loop inside one job.** Not for throttling — see below — but because it gives per-recipient retry with backoff and keeps each job short, so a 5,000-student quiz is not one long-running job holding a lock. It also makes the queue and the ledger 1:1, which is what makes the tracking trustworthy.

---

**Tracking: who received the email and who did not**

`EmailSend` ([`schema.prisma:3589`](../prisma/schema.prisma)) already is this ledger, and the newsletter blast already uses it exactly this way ([`newsletter.service.ts:567`](../src/newsletter/newsletter.service.ts)) — `PENDING` on creation, then `SENT` / `FAILED` / `SKIPPED` with a real `errorMessage`. Reuse it rather than adding a table:

| Field | Holds |
|---|---|
| `category` | `QUIZ_REMINDER` |
| `blastId` | `quiz-reminder-q<quizId>-h<offsetHours>` — the reminder step, already indexed |
| `userId` | the student |
| `recipientEmail` | their email at send time |
| `templateId` | `QuizTemplate.templateId` converted to a number |
| `paramsJson` | the params handed to Brevo |
| `status` | `PENDING` → `SENT` / `FAILED` / `SKIPPED` |
| `sentAt`, `errorMessage` | outcome |

Because `blastId` carries both the quiz and the step, "who got the 24-hour reminder for quiz 42" is one indexed query, and `getBlastStatus` ([`newsletter.service.ts:491`](../src/newsletter/newsletter.service.ts)) is already the shape of the status endpoint. The existing `@@index([category, status])` makes "every quiz reminder that failed" indexed too.

**Students who cannot be emailed are recorded, not skipped silently.** `User.email` is nullable ([`schema.prisma:14`](../prisma/schema.prisma)), and a non-numeric `QuizTemplate.templateId` becomes `NaN` today. Both become a `SKIPPED` row with the reason in `errorMessage`, so "who did not receive it" is a real answer rather than an absence.

**One migration: `@@unique([blastId, userId])` on `EmailSend`.** This is what turns "already sent" from a hope into a guarantee — the send step can create-or-claim and a duplicate is rejected by the database rather than by careful code. It is safe for the newsletter despite the note at [`schema.prisma:3613`](../prisma/schema.prisma) removing an earlier unique key: both newsletter paths set `subscriberId` and leave `userId` null ([`newsletter.service.ts:541`](../src/newsletter/newsletter.service.ts), [`:779`](../src/newsletter/newsletter.service.ts)), and Postgres treats rows as distinct when any column in the key is null, so the constraint cannot fire on them. That is the same reasoning already written into that comment.

Add a compare-and-set claim on the send step as well — `updateMany({ where: { id, status: 'PENDING' }, data: { status: 'SENDING' } })` and only send if the count is 1. BullMQ already guarantees one worker per job, so this is redundant for the normal path; it is what makes a manual "resend the failures" endpoint safe to expose later.

---

**The one real risk: Redis durability**

The seven-day reminder is the **longest-lived promise anything in this document puts on the queue**, so this entry is the one that sets the Redis requirements. They are written up once in "One Redis, not two" above — `appendonly yes` and no `maxmemory` limit on the shared `redis` instance — along with what changed and what each environment still needs checked.

What is specific to this job is the repair. Which reminders should exist is always recomputable from `Quiz.startTime`, so a reconcile routine re-adds the delayed jobs for every future quiz, skipping steps whose moment has passed. Because the job IDs are derived (`quiz-reminder-q<quizId>-h<offsetHours>`), it is a no-op when nothing is wrong and a full repair when Redis has lost something. Run it on boot and expose it as an endpoint.

And note the ledger makes the repair safe at the recipient level too, not just the job level: a reconciled job that fires late writes its snapshot with `skipDuplicates` and only sends to rows that are not already `SENT`, so a repair cannot re-email anyone who was already reached.

---

**Worker placement**

Workers can run in the same containers as the API. Unlike `@Cron`, that is correct rather than a bug: BullMQ hands each job to exactly one worker, so more containers means more capacity, not more copies of the email. A dedicated worker container is worth considering later if sends start competing with request traffic, but it is not needed to make this correct.

---

**The throttle was never needed**

Brevo allows **1,000 requests per second** on the general plan and 2,000 on advanced ([rate limits](https://developers.brevo.com/docs/api-limits)). The real ceiling is the plan's email quota, not the API. So the broken `sleep()` and the "800 emails then wait 2 seconds" block were guarding against a limit that does not exist at this volume — they should be deleted, not fixed. A modest BullMQ limiter is still worth setting so one enormous quiz cannot saturate a worker pool, but it is a courtesy, not a constraint.

---

**Bugs to fix in the same change**

All of these are in the lines being replaced:

- **The one-day query has no `isActive` filter** ([`tasks.service.ts:496`](../src/tasks/tasks.service.ts)). The seven-day query has one; this one does not, so deactivated quizzes still send reminders.
- **Dead query.** `chanakya` ([`tasks.service.ts:491`](../src/tasks/tasks.service.ts)) fetches quiz 17 into a variable nothing reads.
- **The sender name is an email address.** `template.senderEmail` is passed as both address and display name ([`tasks.service.ts:477`](../src/tasks/tasks.service.ts)); `QuizTemplate.senderName` exists and is used correctly at [`quiz.service.ts:1378`](../src/quiz/quiz.service.ts).
- **Duplicate templates double the email.** The lookup is a `findMany` on name + quiz and `QuizTemplate` has no unique constraint, so two rows named `oneDayQuizUpdate` for one quiz means two emails per student. Take one row and log if more than one exists, or add the constraint.
- **`fname + ' ' + lname` renders as "Raj null"** when `lname` is null.
- **Nothing sends in development.** Both `sendBrevoMail` and `sendBrevoMailStrict` are wrapped in `if (process.env.NODE_ENV !== 'development')`, so this path cannot be exercised locally without changing the environment. Worth a deliberate decision on how the queue is tested rather than discovering it during the change.

---

**Open**

- **Is there a three-day step?** The late-registration example given assumed a student registering four days out receives a three-day reminder. Today only two steps exist — `oneWeekQuizUpdate` and `oneDayQuizUpdate` — so under current data that student receives the 24-hour email only. Adding a three-day step is one entry in `REMINDER_STEPS` plus a `QuizTemplate` row per quiz, but the email itself does not exist yet.
- **Whether reminders are platform-scoped.** `QuizTemplate` carries a `platformId` that the code still ignores, and `QuizToUser` has no platform at all. Behaviour is unchanged from the cron here, deliberately — it was not a decision to make while porting.
- **What happens to pending reminders when a quiz is deactivated.** As built, `isActive: false` **cancels** them: `adminUpdateQuiz` reschedules with `replace: true`, which removes the jobs and adds nothing back. If they should instead survive a deactivation, that is a one-line change.

---

**As built**

**Status: IMPLEMENTED** on branch `feature/cron-removal` (uncommitted). One migration, **not yet applied** — see the blocker at the end of this section.

New, under `src/`:

- **`queue/queue.module.ts`** — `BullModule.forRootAsync` on `redis`, `@Global()`, registered once in `app.module.ts`. `forRootAsync` rather than `forRoot` because a module's `imports` array is evaluated at import time, before `.env` is loaded; the factory defers the read. `maxRetriesPerRequest: null` is BullMQ's requirement.
- **`quiz-reminder/quiz-reminder.constants.ts`** — `REMINDER_STEPS` (`[{168h, oneWeekQuizUpdate}, {24h, oneDayQuizUpdate}]`), the derived-id helpers, and the `SEND_STATUS` values.
- **`quiz-reminder/quiz-reminder.service.ts`** — `scheduleForQuiz`, `removeForQuiz`, `reconcile`, `runStep`, `runSend`, `getReminderStatus`.
- **`quiz-reminder/quiz-reminder.processor.ts`** — one `@Processor` switching on job name; `concurrency: 10`, `limiter: 50/s`.
- **`quiz-reminder/quiz-reminder.module.ts`**, imported by `QuizModule` and `CommandModule`.
- **`quiz-reminder/quiz-reminder.service.spec.ts`** — 17 tests, all passing.

Changed:

- **`quiz.service.ts`** — `adminCreateQuiz` and `adminUpdateQuiz` now call a private `scheduleQuizReminders(quizId)` (`replace: true`). It swallows its own errors on purpose: the quiz write has already committed, so a queue problem must not turn a successful edit into a 500, and the boot reconcile is the safety net. Two new admin methods, `adminGetQuizReminders` and `adminReconcileQuizReminders` (removed 2026-10-01), sit beside the other `adminCheckPermission`-gated quiz methods.
- **`command.controller.ts`** — `GET command/quiz/:id/reminders` and `POST command/quiz/reminders/reconcile` (removed 2026-10-01; the boot reconcile still runs), both behind `EmployeeAuthGuard`, delegating to `QuizService` so the permission check stays where the other quiz admin checks are.
- **`tasks.service.ts`** — `sendQuizUpdates` and the broken `sleep()` deleted, with a comment recording where the behaviour went.
- **`schema.prisma`** — `@@unique([blastId, userId])` on `EmailSend`.
- **Three attempt-flow quiz specs** — a `{}` provider for `QuizReminderService`, since `QuizService` gained a constructor argument.

**One correction to the design above, found by running it.** The identifiers were specified as `quiz-reminder:<quizId>:<offsetHours>`. **BullMQ rejects a custom job id containing `:`** unless it happens to split into exactly three parts — a compatibility carve-out for old repeatable jobs that its own source marks for removal. `quiz-reminder:12:24` slipped through by luck; `quiz-reminder-send:12` was refused outright, so every send was silently dropped into the service's error log while the step reported success. Both forms are now colon-free — `quiz-reminder-q<quizId>-h<offsetHours>` and `quiz-reminder-send-<emailSendId>` — and two tests pin that, so neither depends on a rule that is documented to change.

**Verified**

Type check clean (0 errors, down from 31 — the rest were a stale generated Prisma client, fixed by `prisma generate`). `nest build` passes. Test suite identical to baseline: 31 failed suites / 59 failed tests before and after, all pre-existing, with 17 added passes.

Redis, against the `redis-queue` container: `maxmemory-policy noeviction`, `appendonly yes`, `appendfsync everysec`, AOF files present. A key written then subjected to `docker kill` (SIGKILL, so no graceful save — only AOF could recover it) came back with its TTL intact.

End to end, against the local queue and the dev database with the email service stubbed: a quiz 24h + 4s out scheduled exactly one delayed job (the 168h step correctly absent, its moment having passed), the job fired, the snapshot wrote two `PENDING` rows, two send jobs completed, both rows went `SENT` with `sentAt` and `templateId: 699`. The stub was called with `senderName: 'Probe Sender'` rather than the sender's email address, so that bug is fixed. **Re-running the step produced zero extra sends and zero extra rows.** `getReminderStatus` reported `{SENT: 2}, notSent: 0` for the 24h step and `notRecorded: 2` for the 168h step — which is the late-registration rule showing up in the report: nobody was owed a reminder whose moment had already passed.

**BLOCKER — the migration is not applied**

`prisma migrate deploy` fails with `must be owner of table EmailSend`. The `DATABASE_URL` in `.env` connects as **`suraj`**, but the tables are owned by **`gc_dev_app`**, so the role cannot create an index. DML is granted (the end-to-end run inserted and deleted freely); only DDL is refused. The failed attempt was marked rolled back, so `_prisma_migrations` is clean and the migration will be retried on the next deploy.

Someone with the owner role has to apply `prisma/migrations/20260902175719_email_send_blast_user_unique`. It is one statement and safe: verified before writing it that `EmailSend` holds **0 rows with `userId` set and 0 duplicate `(blastId, userId)` groups**.

**The feature works without it** — `runStep` reads the existing rows for the step and only creates what is missing, so the ordinary double-run is handled in code and the end-to-end idempotency check above passed on a database with no such index. What the index adds is the guarantee under a genuine race, where two workers could pass that read simultaneously; it is also what makes the `skipDuplicates` on the `createMany` do anything.

**Also worth knowing before deploying**

- **Nothing sends in development.** Both `sendBrevoMail` and `sendBrevoMailStrict` are wrapped in `if (process.env.NODE_ENV !== 'development')`, so on a dev box a row goes to `SENT` without an email leaving. The end-to-end run stubbed the email service rather than relying on that, but anyone testing by hand should know the ledger will look successful either way.
- **Every environment's `redis` instance needs `appendonly yes` and no `maxmemory` limit before this deploys.** Originally this said `redis_queue` had to be set everywhere; "One Redis, not two" above removed that variable, and with it the silent-fallback failure mode that made the first end-to-end run go wrong. What remains is a check on the existing instance on dev, staging and Coolify, not a provisioning step.

---

### Switched off

Two crons are commented out and should simply be deleted rather than migrated: the newsletter drip campaign ([line 37](../src/tasks/tasks.service.ts)) and a one-off blast to 38,445 addresses ([line 446](../src/tasks/tasks.service.ts)).

---

## B. The one timer outside `tasks.service.ts`

---

### 9. `flushJobViewBuffer` — every 30 seconds ([src/job/cron/job-cron.service.ts:22](../src/job/cron/job-cron.service.ts))

**What it does**
Job page views are counted in a Redis hash instead of one database write per view. Every 30 seconds this empties the hash and sends the totals to the talent service over RabbitMQ. Most of the time the hash is empty. Registered by a second `ScheduleModule.forRoot()` in [`job.module.ts:26`](../src/job/job.module.ts).

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

## C. Timers that are not `@Cron`, but are still scheduled work

These do not show up if you search for "cron", so they are easy to miss.

---

### 10. `submitAfterDelay` — a `setTimeout` per student ([src/quiz/quiz.service.ts:7242](../src/quiz/quiz.service.ts))

**What it does**
When a student connects for a timed quiz, this sets a plain timer for however long they have left, then auto-submits. It lives only in memory, so a deploy or restart kills it silently, and it only exists for students on sockets, not on HTTP.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 11. `flushPendingAnswers` — every 200 milliseconds ([src/quiz/quiz.service.ts:135](../src/quiz/quiz.service.ts))

**What it does**
Groups answer clicks and writes them in one statement instead of one write per click. With thousands of students answering at once this is the difference between a handful of database round-trips and thousands.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 12. `AttemptTransportService.flush` — every 30 seconds ([src/attempt-session/attempt-transport.service.ts:41](../src/attempt-session/attempt-transport.service.ts))

**What it does**
Counts how often each quiz action arrives over sockets versus HTTP and writes the totals to the log. It exists to prove a socket event has stopped being used before we delete it (ticket #215).

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 13. `ResourceMonitorService.sample` — every 15 seconds ([src/common/logger/resource-monitor.service.ts:26](../src/common/logger/resource-monitor.service.ts))

**What it does**
Records CPU, memory and event-loop lag, warns when the server is under strain, and keeps the last reading for the socket logger to attach to its own lines.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 14. `SocketLoggerService.logSnapshot` — every 20 seconds ([src/common/logger/socket-logger.service.ts:25](../src/common/logger/socket-logger.service.ts))

**What it does**
Records how many sockets are connected per namespace, with the resource monitor's latest reading attached.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 15. `SessionStateService.sweep` — every 1 to 5 minutes ([src/interview-bot/common/session-state.service.ts:109](../src/interview-bot/common/session-state.service.ts))

**What it does**
Live interview-bot sessions are held in an in-memory `Map` and only written to the database at the end. This deletes sessions nobody has touched for 30 minutes so memory does not grow forever.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

### 16. `AudioStorageService.sweepCache` — every 6 hours ([src/interview-bot/voice/audio-storage.service.ts:39](../src/interview-bot/voice/audio-storage.service.ts))

**What it does**
Deletes cached text-to-speech files older than 24 hours, then trims oldest-first if the folder is over 200MB. Also runs once at boot.

**Context**
_To be filled in._

**Solution**
_Not decided yet._

---

## Admin endpoints removed (2026-10-01)

Eight status and repair endpoints added during this work had no caller in any org repo and no prod traffic (16–30 Sep), so they were removed:
`POST quiz/reminders/reconcile`, `GET whatsapp-reminders/window`, `GET enrollment/:id/checkin`, `POST whatsapp-reminders/reconcile`, `GET lead-reset/status`, `GET schedule-call/:id/reminder`, `POST schedule-call/reminders/reconcile`, `GET leads/:id/schedule-dispatch`, together with the service methods only they called.

None of them ran a job. The BullMQ processors and the paths that enqueue jobs are unchanged, and so is the Redis-loss repair:

- Quiz reminders, schedule-call reminders and scheduled-lead dispatch already reconciled on boot.
- WhatsApp reminders did not, so `WhatsappReminderService` now does. It is PENDING-only and add-only, because every container runs it on every deploy. Retrying FAILED sends is done deliberately, by re-running their window through `POST whatsapp-reminders/run?date=`.

`POST leads/schedule-dispatch/reconcile`, `GET quiz/:id/reminders`, `GET lead/:id/nudge` and both `run` endpoints were not on the list and stay.

---

## When everything above is done

Three things get deleted: `ScheduleModule.forRoot()` (currently registered twice — [`app.module.ts:59`](../src/app.module.ts) and [`job.module.ts:26`](../src/job/job.module.ts)), `TasksService` and `TasksModule` once they are empty, and the `@nestjs/schedule` package itself. Uninstalling the package is the check that proves the job is finished.

One thing arrives rather than leaves: `bullmq`, running on the Redis instance this project already had (see "One Redis, not two"). That is a deliberate trade — `@nestjs/schedule` runs every job in every container with no record, no retry and no way to express "at a moment derived from data". Note the swap is not finished when the package is gone: **every environment's Redis must have `appendonly yes` and no `maxmemory` limit before any entry that uses the queue is deployed.** Dev, staging and Coolify still need that confirmed.
