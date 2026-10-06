# Call Recording — Chunked Upload API

**For:** Dialer app developer
**Backend:** `src/command/command.controller.ts` + `src/command/command.service.ts` + `src/vultr/vultr.service.ts`
**Status:** ✅ Backend built, unit-tested, e2e-tested with real HTTP, and the presigned-URL flow verified against the live Vultr bucket with a plain `PUT` (no SDK) — exactly how a real client uses it. Nothing on the client implements this yet — this doc is the full contract to build against.

---

## Table of Contents

1. [Why this exists](#1-why-this-exists)
2. [Before you start](#2-before-you-start)
3. [The flow, at a glance](#3-the-flow-at-a-glance)
4. [Endpoint reference](#4-endpoint-reference)
5. [Rules you must follow](#5-rules-you-must-follow)
6. [Error responses](#6-error-responses)
7. [Worked example (curl)](#7-worked-example-curl)
8. [Retry / failure handling](#8-retry--failure-handling)
9. [Postman collection](#9-postman-collection)
10. [FAQ](#10-faq)

---

## 1. Why this exists

The app already uploads call recordings via one endpoint:

```
POST /api/command/call-recording/:interactionId
```

— the whole file, buffered through our backend server, in a single request. That endpoint still exists and still works, but it has a hard 150MB cap, and a single large request is exactly the kind of thing that fails on a bad mobile connection (times out, gets dropped, no retry). When that happens, the call still gets logged, it just silently ends up with no recording — no error the user sees, nothing to retry.

The flow below fixes that two ways at once:

1. **Chunked, not whole-file.** The recording is split into pieces, each piece is its own small request, and a failed piece can be retried on its own without resending everything already uploaded.
2. **Direct to storage, not through our server.** The actual chunk bytes are `PUT` straight from the device to Vultr — our backend only *authorizes* each step and hands back a short-lived signed URL. Our server never buffers or proxies the audio data at all.

**Use this flow for anything that isn't trivially small.** The old single-shot endpoint is still fine for short recordings if you want to keep using it there, but don't build new long-recording logic against it.

---

## 2. Before you start

- **No new auth work.** Use the exact same `deviceId` query parameter the app already sends on the existing single-shot endpoint. Nothing about identity/auth changes for this flow.
- **You need a real `interactionId`.** This is the ID of the call record the recording belongs to — the app already has this from whatever flow triggers a recording upload today.
- **Two different destinations.** `start`, `part-url`, `complete`, and `abort` all go to *our backend* (`/api/command/call-recording/...`). The actual chunk upload is a `PUT` straight to *Vultr* using the URL `part-url` gives you — that request does not go through our server and needs none of our headers.

---

## 3. The flow, at a glance

```
1. START      →  our backend: tell it you're about to upload, get back an uploadId + fileName
2. PART-URL   →  our backend: ask for a signed upload URL for this one chunk
3. PUT        →  Vultr directly: upload the chunk's bytes to that URL, read the ETag back
   (repeat 2-3 for each chunk)
4. COMPLETE   →  our backend: submit every eTag together, it tells Vultr to assemble the file
   (or)
   ABORT      →  our backend: if you give up partway through, clean up
```

`uploadId` and `fileName` come back from step 1 — treat them as opaque tokens. Don't construct them yourself; just pass back exactly what the server gave you on every subsequent call.

---

## 4. Endpoint reference

### 4.1 Start

```
POST /api/command/call-recording/:interactionId/start?deviceId=<deviceId>
Content-Type: application/json
```

**Body:**

```json
{
  "fileExtension": "m4a",
  "contentType": "audio/mp4"
}
```

| Field | Type | Notes |
|---|---|---|
| `fileExtension` | string | Alphanumeric, no dot, max 10 chars (e.g. `"m4a"`, `"mp3"`) |
| `contentType` | string | Must be one of the [allowed audio MIME types](#5-rules-you-must-follow) |

**Response `200`:**

```json
{
  "uploadId": "2~QBHIc588CrxQrp2HcCn5C3Rsx0k1Ggx",
  "fileName": "CRM/platform/recordings/phone_recording_501_9876543210_a1b2c3.m4a"
}
```

Save both values — every request below needs them.

---

### 4.2 Get a part upload URL

Call this once per chunk, `partNumber` starting at 1. **This goes to our backend** — it does not receive the chunk itself, only issues a URL for you to upload to.

```
POST /api/command/call-recording/:interactionId/part-url?deviceId=<deviceId>
Content-Type: application/json
```

**Body:**

```json
{
  "fileName": "CRM/platform/recordings/phone_recording_501_9876543210_a1b2c3.m4a",
  "uploadId": "2~QBHIc588CrxQrp2HcCn5C3Rsx0k1Ggx",
  "partNumber": 1
}
```

**Response `200`:**

```json
{
  "partNumber": 1,
  "url": "https://blr1.vultrobjects.com/crm/CRM/platform/...&X-Amz-Signature=..."
}
```

`url` is a signed link valid for **1 hour**. Use it once, for step 4.3 below, before it expires.

---

### 4.3 Upload the chunk to Vultr

**This does NOT go to our backend.** `PUT` the chunk's raw bytes straight to the `url` from the previous step:

```
PUT <url from part-url response>
Body: <the chunk's raw bytes>
```

No `deviceId`, no `dauth`, no JSON — just the bytes, as the request body. Vultr returns the part's `ETag` in a **response header**, not a JSON body:

```
HTTP/1.1 200 OK
ETag: "f1f314fa77d857debc18ae8f73a24ea7"
```

Read the `ETag` header and store it against this `partNumber` — you need the full list for `complete`. It includes the quote characters shown above; send it back exactly as received, don't strip them.

---

### 4.4 Complete

Call once, after every chunk has been `PUT` to Vultr successfully. **Back to our backend.**

```
POST /api/command/call-recording/:interactionId/complete?deviceId=<deviceId>
Content-Type: application/json
```

**Body:**

```json
{
  "fileName": "CRM/platform/recordings/phone_recording_501_9876543210_a1b2c3.m4a",
  "uploadId": "2~QBHIc588CrxQrp2HcCn5C3Rsx0k1Ggx",
  "parts": [
    { "eTag": "\"f1f314fa77d857debc18ae8f73a24ea7\"", "partNumber": 1 },
    { "eTag": "\"a9b8c7d6e5f4...\"", "partNumber": 2 }
  ],
  "contentType": "audio/mp4"
}
```

`contentType` here must match what you sent in step 1.

**Response `200`:**

```json
{
  "link": "https://blr1.vultrobjects.com/crm/CRM/platform/recordings/phone_recording_501_9876543210_a1b2c3.m4a",
  "type": "audio/mp4"
}
```

This is the call that makes the recording's play button appear in the CRM's Calling Insight screen. Nothing further needs to happen on your end after this succeeds.

---

### 4.5 Abort

Only call this if you're giving up mid-upload (user cancelled, app backgrounded and you're not resuming, etc.) — not part of the normal happy path. **Our backend.**

```
POST /api/command/call-recording/:interactionId/abort?deviceId=<deviceId>
Content-Type: application/json
```

**Body:**

```json
{
  "fileName": "CRM/platform/recordings/phone_recording_501_9876543210_a1b2c3.m4a",
  "uploadId": "2~QBHIc588CrxQrp2HcCn5C3Rsx0k1Ggx"
}
```

**Response `200`:**

```json
{ "message": "Upload aborted" }
```

---

## 5. Rules you must follow

- **Chunk size:** target **8MB** per chunk. There's no longer a size limit enforced by *our* server (it never receives the bytes) — the limits that apply now are Vultr's own S3 multipart rules below. 8MB is still a good target purely for retry-friendliness: smaller chunks mean less to redo when one fails.
- **S3 multipart rule (enforced by Vultr, not us):** every chunk *except the last* must be **at least 5MB**; each part can be up to 5GB. Only your final chunk is allowed to be under 5MB. (A file small enough to fit in a single chunk has no minimum — that one chunk is automatically "the last one".)
- **`contentType` allowlist** — `start` and `complete` both reject anything outside this list with a `400`:
  ```
  audio/mpeg, audio/wav, audio/ogg, audio/aac, audio/amr, audio/flac,
  audio/webm, audio/mp4, audio/x-m4a, audio/x-wav, audio/x-aiff,
  audio/aiff, audio/x-ms-wma, audio/opus
  ```
- **`partNumber` must be sequential and unique** per upload session — don't skip numbers, don't reuse one.
- **Don't invent `fileName`/`uploadId`.** They're generated server-side in `start` and scoped to that specific `interactionId` — sending a `fileName` from a different interaction (or a made-up one) is rejected with `403` at `part-url`/`complete`/`abort`.
- **Presigned URLs expire in 1 hour.** Use each one immediately for its `PUT`; don't cache and reuse it later.

---

## 6. Error responses

**From our backend** (`start`, `part-url`, `complete`, `abort`):

| Status | Meaning | What to do |
|---|---|---|
| `400` Bad Request | Invalid body (bad `contentType`, missing field, `partNumber` out of range, empty `parts` list on complete) | Fix the request — this won't succeed on retry without a change |
| `403` Forbidden | `fileName` doesn't belong to this `interactionId` (or, on the single-shot endpoint, the file's mimetype isn't in the allowlist) | Bug in your client — you're sending back a `fileName` you didn't get from `start` |
| `404` Not Found | `interactionId` + `deviceId` don't match a real call record | Check you're using the right `interactionId`/`deviceId` pair |
| `5xx` | Something failed on the server side (Vultr, database) | Safe to retry — see [§8](#8-retry--failure-handling) |

**From Vultr directly** (the `PUT` to the presigned URL) — these are raw S3-style XML error responses, not our JSON shape:

| Status | Meaning | What to do |
|---|---|---|
| `403 Forbidden` (`SignatureDoesNotMatch` / `AccessDenied`) | URL expired (>1hr old) or was modified/truncated | Call `part-url` again for a fresh URL, don't reuse an old one |
| `400 Bad Request` (`EntityTooSmall`) | A non-final chunk was under 5MB | Fix your chunking — only the last chunk may be under 5MB |

---

## 7. Worked example (curl)

```bash
BASE="https://your-server/api/command/call-recording"
INTERACTION_ID=501
DEVICE_ID="your-device-id"

# 1. Start (our backend)
curl -X POST "$BASE/$INTERACTION_ID/start?deviceId=$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d '{"fileExtension":"m4a","contentType":"audio/mp4"}'
# → { "uploadId": "...", "fileName": "..." }

# 2. Get a URL for part 1 (our backend)
curl -X POST "$BASE/$INTERACTION_ID/part-url?deviceId=$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d '{"fileName":"<fileName from step 1>","uploadId":"<uploadId from step 1>","partNumber":1}'
# → { "partNumber": 1, "url": "https://..." }

# 3. PUT the chunk straight to Vultr (NOT our backend) — read ETag from the response header
curl -i -X PUT "<url from step 2>" --data-binary @chunk1.bin
# → HTTP/1.1 200 OK
#   ETag: "f1f314fa77d857debc18ae8f73a24ea7"

# 4. Complete (our backend)
curl -X POST "$BASE/$INTERACTION_ID/complete?deviceId=$DEVICE_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "fileName": "<fileName from step 1>",
    "uploadId": "<uploadId from step 1>",
    "parts": [{ "eTag": "\"f1f314fa77d857debc18ae8f73a24ea7\"", "partNumber": 1 }],
    "contentType": "audio/mp4"
  }'
# → { "link": "https://...", "type": "audio/mp4" }
```

---

## 8. Retry / failure handling

- **A `PUT` to Vultr fails (network error, timeout, 5xx, or a `403` from an expired URL):** call `part-url` again for that `partNumber` to get a fresh URL, then retry the `PUT`. Don't restart from `start` and don't re-upload parts that already succeeded.
- **The app is killed / user cancels mid-upload:** call `abort` if you can. If you can't (app already gone), it's not catastrophic — the partial upload just sits unfinished on Vultr's side; it doesn't create a broken recording anyone will see, since nothing shows up in the CRM until `complete` succeeds.
- **`complete` fails:** safe to retry with the exact same `parts` list, as long as you still have every `eTag`. If you've lost track of which parts succeeded, don't guess — start over from `start` with a fresh upload.
- **Don't retry a `400` or `403` from our backend without changing the request** — those mean something about the request itself is wrong, not a transient failure. A `403`/`400` *from Vultr* on the `PUT`, though, usually just means "get a new URL and retry" (see §6).

---

## 9. Postman collection

A ready-to-import collection exercising this entire flow (including the direct-to-Vultr `PUT` step and negative/error cases) lives at:

```
src/command/call-recording-postman/collection.json
```

with setup instructions in `src/command/call-recording-postman/README.md`. Useful for confirming your understanding of the contract against a real server (and the real bucket) before writing client code.

---

## 10. FAQ

**Q: Why does the chunk upload go straight to Vultr instead of through the backend, like `part-url` does?**
A: So our server never has to hold recording bytes in memory or spend bandwidth proxying them — it only ever handles small JSON requests (issue a URL, record a finished link). The actual data transfer happens directly between the device and storage.

**Q: What if the recording is small enough to fit in one chunk?**
A: Still works — get one `part-url`, `PUT` it, then `complete` with just that one entry in `parts`. There's no minimum size for a single-part upload.

**Q: Can chunks be uploaded in parallel?**
A: Yes — get multiple `part-url`s and run their `PUT`s concurrently if you want. `partNumber` just needs to be correct and unique per chunk; order of arrival doesn't matter. Sequential is simpler to get right first.

**Q: Does `deviceId` need to match anything special?**
A: It needs to resolve to the same device/employee that owns the `interactionId` you're uploading against — same requirement as the existing single-shot endpoint you already call today.

**Q: What happens to the old single-shot endpoint?**
A: It's untouched and still works. Nothing is being removed.
