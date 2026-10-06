# Quiz & Practice Attempt HTTP API

The HTTP counterpart to the `/user` socket's quiz/practice attempt events (GrowthCommand#204 epic; implemented in #205–#212). **Sockets are not going away** — they still carry `quiz-start`, `quiz-end`, `watching-question`, `is-online`, chat, and WebRTC. Only the request/response half of taking a quiz or doing practice moves to these endpoints.

Frontend counterpart: `Leveraged-Growth/LMS_V2` **#81** (children #82–#88). This document is the merged contract those tickets implement against — where it disagrees with the epic's draft table, this document is authoritative, since it is generated from the code as merged.

---

## Authentication

Every endpoint below requires:

```
Authorization: Bearer <user_jwt>
```

plus a resolvable platform, exactly like every other `/api/user`, `/api/quiz`, `/api/practice` route:

```
Origin: <platform origin>
```
or
```
dauth: <platform auth key>
```

There is **no socket `login` step** for these endpoints — the JWT alone establishes identity. The existing `AuthGuard` (`path: 'auth'`) is what enforces this; a request without a valid token gets `401`.

---

## The `quizPracticeTransport` flag

Each platform can be in one of three modes, stored as a `PlatformOptions` row (`key: 'quizPracticeTransport'`, `valueText`) and cached the same way `canUsePractice`/`canUseQuiz`/`isDevice` already are:

| `valueText` | HTTP `attempt/*` endpoints | Socket attempt events |
|---|---|---|
| `socket` | `405 Method Not Allowed` | Work normally |
| `dual` (default — no row, or an unrecognised value) | Work normally | Work normally |
| `http` | Work normally | Reject with the operation's existing `*-error` event, message: *"This platform has moved to HTTP for this operation - use the REST attempt endpoints instead"* |

Non-attempt socket traffic — `login`, `identify`, `watch-course`, WebRTC signaling, chat — is **unaffected by this flag in every mode**.

**Read it via the existing platform-options endpoint** — no new endpoint was added:

```
GET /api/platform/meta?key=quizPracticeTransport
```

Response is an array (it's a `findMany`); read `response[0]?.valueText`. No row, or a value that isn't `socket`/`http`, means `dual`.

Flipping the value is a plain DB write — no redeploy — but it's cached with a ~5 minute TTL (`REFERENCE_DATA_TTL_MS`, default `300000ms`), so a flip is not visible instantly to a request that lands a moment later.

---

## Client obligations (things the socket path used to handle implicitly)

1. **Resume on mount.** Call `GET /attempt/current` (quiz or practice) when the attempt screen mounts. If it returns a live session, restore it — including the current question and elapsed time — instead of starting fresh. A page reload no longer loses the attempt, but only if the client asks.
2. **Heartbeat while an attempt is open.** `POST /attempt/heartbeat` on an interval — every other attempt call already refreshes the session's `lastSeenAt`, so the heartbeat only needs to cover idle stretches (a student reading a long question). Recommended interval: **30–60s** — the server sweeps stale sessions every 30s with a 90s grace period, so a 30s heartbeat leaves a full sweep cycle of margin; don't push past ~60s or that margin disappears.
3. **Explicit pause on unload.** `POST /attempt/pause` on `beforeunload`/`pagehide` (use `navigator.sendBeacon` or a keepalive `fetch` — a plain `fetch` during unload is not reliably delivered) and on in-app navigation away from the attempt screen. Without it, a closed tab's elapsed time is only flushed later by the stale-session sweeper, not immediately.
4. **Keep the socket connected** for `quiz-start`, `quiz-end`, `watching-question`, `is-online` — these have no HTTP equivalent and never will.
5. **Read `quizPracticeTransport`** (above) at boot to decide which transport to use for attempt calls.

---

## Practice endpoints

Base path: `/api/practice/attempt`. All require the auth above; all are gated by the transport flag (§ above) and by the existing `canUsePractice` platform check (`405` if practice is disabled for the platform, same as today).

### Start a practice attempt

Replaces socket event: `make-practice-attempt`

```
POST /api/practice/attempt/start
```

**Body** (all fields optional):

```json
{
  "questionCount": 5,
  "includeEasy": true,
  "includeMedium": true,
  "includeHard": true,
  "isFlagged": false,
  "isIncorrect": false,
  "isUnattempted": false,
  "subjectIds": [1, 2],
  "otherSubject": false,
  "questionIds": ["101", "102"],
  "attemptId": 456
}
```

Pass `attemptId` to explicitly resume a specific attempt. **Idempotent start**: even without `attemptId`, if the caller already has a live, unsubmitted attempt, that attempt is returned instead of a new one being created — safe to retry on a timeout or double-tap.

**Response** `200/201` — the attempt, with its questions:

```json
{
  "id": 456,
  "userId": 84819,
  "courseId": 12,
  "timeTaken": 0,
  "hasSubmitted": false,
  "Answer": [
    {
      "id": 9001,
      "attemptId": 456,
      "questionId": 101,
      "optionId": null,
      "essayText": null,
      "timeTaken": 0,
      "hasSubmitted": false,
      "order": 1,
      "Question": {
        "id": 101,
        "question": "...",
        "type": "mcq",
        "Option": [{ "id": 5, "option": "..." }],
        "UserFlag": [],
        "Report": [],
        "FallNumber": [ /* subject chain */ ]
      }
    }
  ]
}
```

Use `Answer[0].questionId` as the first question to watch.

---

### Get the current attempt

Replaces: (new — no socket equivalent; enables resume-on-reload)

```
GET /api/practice/attempt/current
```

**Response** — the session, or `null` if there's nothing live:

```json
{
  "courseId": 12,
  "attemptId": 456,
  "attemptStartTime": "2026-08-26T10:00:00.000Z",
  "questionId": 101,
  "questionStartTime": "2026-08-26T10:00:05.000Z",
  "hasSubmited": false,
  "lastSeenAt": 1735200000000,
  "transport": "http"
}
```

---

### Get a parent question

Replaces: `get-practice-parent-question`

```
GET /api/practice/attempt/parent-question?questionId=<id>
```

| Param | Type | Required |
|---|---|---|
| `questionId` | string | Yes |

**Response** `200` — the parent question, with its not-yet-attempted child questions:

```json
{
  "id": 90,
  "question": "...",
  "Questions": [
    {
      "id": 101,
      "question": "...",
      "Explaination": { "...": "..." },
      "Attempt": [{ "optionId": 5, "createdAt": "..." }],
      "Option": [{ "id": 5, "option": "...", "RightOption": {}, "Explaination": {} }],
      "FallNumber": [ /* subject chain */ ]
    }
  ]
}
```

`404` if the question has no parent (`questionId` on the child is null).

---

### Watch a question

Replaces: `watch-practice-question`

```
POST /api/practice/attempt/watch-question
```

**Body**

```json
{ "questionId": 101 }
```

**Response** `200/201` — the `UserPracticeAnswer` row for that question:

```json
{
  "id": 9001,
  "attemptId": 456,
  "questionId": 101,
  "optionId": null,
  "essayText": null,
  "timeTaken": 0,
  "hasSubmitted": false,
  "difficulty": null,
  "isCorrect": null
}
```

**Call this on every question change, before rendering the next question.** It's what stops accruing time on the previous question and starts it on the new one — skip or debounce it and per-question `timeTaken` is wrong.

`400` if there's no live attempt or the question isn't part of it.

---

### Answer with an option

Replaces: `add-option-practice-question`

```
POST /api/practice/attempt/answer/option
```

**Body**

```json
{ "questionId": 101, "optionId": 5 }
```

**Response** `200/201` — updated `UserPracticeAnswer` row (same shape as watch-question above). Sending the same `optionId` again **toggles it off** (`optionId` → `null`) rather than erroring.

`409` if the question or the attempt is already submitted. `404` if the question isn't part of the attempt.

---

### Answer with essay text

Replaces: `add-essay-practice-question`

```
POST /api/practice/attempt/answer/essay
```

**Body**

```json
{ "essay": "free text answer" }
```

**Response** `200/201` — updated `UserPracticeAnswer` row (`essayText` set). Same `409`/`404` rules as above.

---

### Self-mark an essay answer

Replaces: `mark-essay-practice-question`

```
POST /api/practice/attempt/answer/essay/mark
```

**Body**

```json
{ "isCorrect": true }
```

**Response** `200/201` — updated `UserPracticeAnswer` row. `400` unless the attempt or that question is already submitted — this is for self-review after the fact, not during the live attempt.

---

### Get a question's explanation

Replaces: `get-practice-question-explaination`

```
GET /api/practice/attempt/question-explanation?questionId=<id>
```

| Param | Type | Required |
|---|---|---|
| `questionId` | integer | Yes |

Must equal the currently-watched question in the session, or `400`.

**Response** `200`:

```json
{
  "id": 101,
  "question": "...",
  "Option": [
    { "id": 5, "option": "...", "RightOption": { "optionId": 5 }, "Explaination": { "text": "..." } }
  ],
  "Explaination": { "text": "..." }
}
```

**This deliberately reveals the right answer for the requested question** and marks it `hasSubmitted` server-side — call it only when the student asks to see the explanation, not proactively.

---

### Rate a question's difficulty

Replaces: `add-practice-question-difficulty`

```
POST /api/practice/attempt/question-difficulty
```

**Body**

```json
{ "difficulty": "easy" }
```

`difficulty` is one of `"easy" | "medium" | "hard"` (stored internally as `1`/`5`/`10`).

**Response** `200/201` — updated `UserPracticeAnswer` row.

---

### Submit the attempt

Replaces: `submit-practice-attempt`

```
POST /api/practice/attempt/submit
```

No body.

**Response** `200/201`:

```json
{ "message": "Attempt submitted" }
```

**Idempotent** — a retried call after the first success returns the same message, not an error. `400` if there's no live attempt.

---

### Pause the attempt

Replaces: `pause-practice-attempt`

```
POST /api/practice/attempt/pause
```

No body.

**Response** `200/201`:

```json
{ "message": "Attempt paused" }
```

Flushes elapsed time and clears the session. Call this on unload/route-change (see Client Obligations above). `400` if there's no live attempt.

---

### Heartbeat

Replaces: (new — see Client Obligations above)

```
POST /api/practice/attempt/heartbeat
```

No body, empty `200` response. Purely refreshes `lastSeenAt`.

---

## Quiz endpoints

Base path: `/api/quiz/attempt`. All require the auth above; all are gated by the transport flag and the existing `canUseQuiz` platform check.

### Start a quiz attempt

Replaces: `make-quiz-attempt`

```
POST /api/quiz/attempt/start
```

**Body** — exactly one of these three:

```json
{ "quizId": 10 }
```
```json
{ "attemptId": 456 }
```
```json
{ "slug": "algebra-mock-1" }
```

**Response** `200/201` — **not the attempt row.** Unlike practice's start endpoint, this returns a confirmation envelope plus the quiz metadata; `quiz.Questions` is deliberately `null` here — fetch the actual question/answer list separately via `GET /attempt/questions` right after start:

```json
{
  "message": "Attempted successfully",
  "quiz": {
    "id": 10,
    "name": "Algebra Mock 1",
    "accessType": "open",
    "timeType": "unlimited",
    "resultType": "aftersubmit",
    "Questions": null,
    "Meta": { "...": "..." },
    "Groups": [ /* registered-group quizzes only */ ],
    "Attempts": [
      { "id": 456, "userId": 101, "quizId": 10, "timeTaken": 0, "hasSubmitted": false }
    ]
  },
  "watchingQuestions": [
    { "user": { "id": 205 }, "quizId": 456, "questionId": 900 }
  ]
}
```

Use `quiz.Attempts[0].id` as the attempt id if you need it before calling `GET /attempt/questions` (that call, and everything after it, reads the attempt off the session instead, so you rarely need to thread this id through by hand). `watchingQuestions` is the `registered-group` peer-presence seed — the socket path emits these as individual `watching-question` events as they're discovered; HTTP has no caller socket to emit to, so they're batched into this array instead. Empty for non-group quizzes.

---

### Get the current attempt

Replaces: (new — no socket equivalent)

```
GET /api/quiz/attempt/current
```

**Response** — the session, or `null`:

```json
{
  "attemptId": 456,
  "quizId": 10,
  "attemptStartTime": "2026-08-26T10:00:00.000Z",
  "questionId": 900,
  "questionStartTime": "2026-08-26T10:00:05.000Z",
  "hasSubmited": false,
  "lastSeenAt": 1735200000000,
  "transport": "http"
}
```

Use `attemptStartTime`/`questionStartTime` (not a locally-held timestamp) to rebuild any countdown after a pause/reload — that's what makes the countdown survive a reconnect.

---

### Get all questions

Replaces: `give-quiz-questions`

```
GET /api/quiz/attempt/questions
```

**Response** `200` — the attempt, its questions, and (new) the live peer list:

```json
{
  "id": 456,
  "quizId": 10,
  "hasSubmitted": false,
  "Quiz": { "id": 10, "name": "...", "Attempts": [ /* teammates, group quizzes only */ ] },
  "Answers": [ { "id": 9001, "questionId": 900, "Question": { "...": "..." } } ],
  "onlineUserIds": [101, 205]
}
```

`onlineUserIds` is new: on the socket path, the peer list arrived via a separate `is-online` push to the caller. On HTTP, it's in this response body instead. Calling this endpoint also triggers a `came-online` broadcast to the live group room (unchanged behavior, still socket-delivered to peers).

**Anti-cheat boundary**: for every `Answers[].Option`, `RightOption` and `Explaination` are present **only once the attempt is submitted** (`hasSubmitted: true`); otherwise they're omitted entirely from the response. This must never be visible before submit — see `src/quiz/quiz.service.ts` around the `session.hasSubmited ? true : false` include guards.

---

### Watch a question

Replaces: `watch-quiz-question`

```
POST /api/quiz/attempt/watch-question
```

**Body**

```json
{ "questionId": 900 }
```

**Response** `200/201`:

```json
{ "questionId": 900 }
```

Thinner than practice's equivalent — it does not return the answer row; fetch it via `GET /attempt/questions` if needed. Also broadcasts `watching-question` to the live group room, same as before. **Call this on every question change, before rendering the next question** — same time-accrual reason as practice.

---

### Get a parent question

Replaces: `get-quiz-parent-question`

```
GET /api/quiz/attempt/parent-question?questionId=<id>
```

| Param | Type | Required |
|---|---|---|
| `questionId` | integer | Yes |

**Response** `200`:

```json
{ "Question": { "id": 800, "question": "..." } }
```

The parent question is nested under a `Question` key (not top-level, unlike practice's parent-question response).

---

### Answer with an option

Replaces: `add-option-quiz-question`

```
POST /api/quiz/attempt/answer/option
```

**Body**

```json
{ "optionId": 5 }
```

No `questionId` field — it targets whichever question the session is currently watching.

**Response** `200/201` — the updated answer (a plain merged object, no nested relations):

```json
{
  "id": 9001,
  "attemptId": 456,
  "questionId": 900,
  "optionId": 5,
  "timeTaken": 12,
  "updatedAt": "2026-08-26T10:05:00.000Z"
}
```

Same `optionId` again toggles it off. For `registered-group` quizzes, also broadcasts `updated-question-option` to teammates and clears their pending selection on that question. `409` if the question or attempt is already submitted.

---

### Answer with essay text

Replaces: `add-essay-quiz-question`

```
POST /api/quiz/attempt/answer/essay
```

**Body**

```json
{ "essay": "free text answer" }
```

**Response** `200/201` — updated answer row (`essayText` set).

---

### Self-mark an essay answer

Replaces: `mark-essay-quiz-question`

```
POST /api/quiz/attempt/answer/essay/mark
```

**Body**

```json
{ "isCorrect": true }
```

**Response** `200/201` — updated answer row. `400` unless the attempt is already submitted.

---

### Get the current question's explanation

Replaces: `get-quiz-question-explaination`

```
GET /api/quiz/attempt/question-explanation
```

**No query params** — unlike practice, this always targets the session's current `questionId`.

**Response** `200`:

```json
{
  "id": 900,
  "question": "...",
  "Option": [{ "id": 5, "option": "...", "RightOption": {}, "Explaination": {} }],
  "Explaination": { "text": "..." },
  "Answers": [{ "optionId": 5, "hasSubmitted": true }]
}
```

Same deliberate-reveal semantics as practice: calling it marks the question `hasSubmitted`.

---

### Rate a question's difficulty

Replaces: `add-quiz-question-difficulty`

```
POST /api/quiz/attempt/question-difficulty
```

**Body**

```json
{ "difficulty": "hard" }
```

**Response** `200/201` — updated answer row.

---

### Submit the attempt

Replaces: `submit-quiz-attempt`

```
POST /api/quiz/attempt/submit
```

No body.

**Response** `200/201`:

```json
{ "message": "Attempt submitted" }
```

**Idempotent.** For `registered-group` quizzes, **only the team captain may call this** — every other member gets `403 Only team leader can submit this quiz`. On success, `hasSubmitted` cascades to every teammate's attempt automatically.

---

### Pause the attempt

Replaces: `pause-quiz-attempt` (this event has always called the same underlying handler as a socket disconnect — pause and disconnect-cleanup are the same code path, now also shared with the HTTP endpoint and the stale-session sweeper)

```
POST /api/quiz/attempt/pause
```

No body.

**Response** `200/201`:

```json
{ "message": "Attempt paused" }
```

---

### Heartbeat

Replaces: (new — see Client Obligations above)

```
POST /api/quiz/attempt/heartbeat
```

No body, empty `200` response.

---

## Common error responses

| Status | Meaning on these endpoints |
|---|---|
| `400 Bad Request` | Invalid input, no live attempt, question not part of this attempt, question not currently watched |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Not the team captain (group-quiz submit) |
| `404 Not Found` | Attempt, question, or parent question doesn't exist |
| `405 Method Not Allowed` | Practice/quiz disabled for this platform, or this platform's `quizPracticeTransport` is `socket` |
| `409 Conflict` | The question or attempt is already submitted |

Response body follows Nest's default `HttpException` shape:

```json
{ "statusCode": 409, "message": "Attempt already submitted", "error": "Conflict" }
```

For validation failures, `message` is an **array** of strings instead of one:

```json
{ "statusCode": 400, "message": ["difficulty must be one of the following values: easy, medium, hard"], "error": "Bad Request" }
```

---

## Typical flows

### Practice — full attempt

```
1. POST /api/practice/attempt/start                       → get attemptId + first question
2. POST /api/practice/attempt/watch-question               → start the clock on question 1
3. POST /api/practice/attempt/answer/option (or /essay)    → answer it
4. POST /api/practice/attempt/watch-question               → move to question 2 (stops clock on Q1, starts on Q2)
   ... repeat 3-4 for remaining questions ...
5. POST /api/practice/attempt/submit                        → done
6. GET  /api/practice/attempt/question-explanation          → (optional) review answers
```

Heartbeat (`POST /attempt/heartbeat`) runs in the background throughout; `POST /attempt/pause` fires on unload/navigation-away instead of step 5 if the student leaves early.

### Quiz — self-paced

```
1. POST /api/quiz/attempt/start           → { quizId } or { slug }; response is a confirmation envelope, not the attempt - see below
2. GET  /api/quiz/attempt/questions        → full question list, RightOption/Explaination withheld
3. POST /api/quiz/attempt/watch-question   → per question
4. POST /api/quiz/attempt/answer/option (or /essay)
   ... repeat 3-4 ...
5. POST /api/quiz/attempt/submit           → RightOption/Explaination now included on question 2's re-fetch
```

### Quiz — scheduled / group

Same as self-paced, plus:

- Client stays connected to the `/user` socket for `quiz-start` (moves the student out of the waiting room) and `quiz-end` (server-enforced; a write after `endTime` returns `409` even if the push was missed).
- `GET /attempt/questions`'s `onlineUserIds` seeds the presence UI; `watching-question` pushes keep it live.
- Only the team captain calls `submit` for the group.

### Resuming after a reload, at any point in either flow

```
GET /api/{quiz,practice}/attempt/current
```
→ if a live session comes back, rejoin at `questionId` with the returned `questionStartTime`/`attemptStartTime` instead of restarting.

---

## What's intentionally different from the socket path

These are **known, intended** differences — not bugs, not gaps in the migration:

- The socket path replies with `<event>-success` / `<event>-error`; HTTP replies with a response body and a status code.
- `give-quiz-questions`'s socket-only `is-online` emit is folded into `GET /attempt/questions`'s `onlineUserIds` field.
- `make-quiz-attempt`'s socket-only per-peer `watching-question` emits (discovered while building the response) are folded into `POST /attempt/start`'s `watchingQuestions` array, same reasoning as `is-online` above.
- Everything else (DB effects, broadcasts to `/user` peers, anti-cheat gating, idempotent start/submit, per-attempt locking) is identical between transports by construction — both transports read and write the same Redis-backed attempt session (GrowthCommand#205) and the same `*V2` service methods are the single source of truth either way.

---

## Related

- Epic: GrowthCommand#204 (backend), `Leveraged-Growth/LMS_V2`#81 (frontend)
- Implementation tickets: #205 (session store), #206/#207 (transport-agnostic cores), #208/#209 (these endpoints), #210 (heartbeat/sweeper), #211 (locking/idempotency), #212 (transport flag/counters)
- Postman collection: `postman/quiz-practice-attempt-http.postman_collection.json`
- `docs/socket-microservice-migration.md` — the separate spec for the socket server itself; §4.2 and §8 there are updated alongside this document to reflect which events are moving to HTTP.
