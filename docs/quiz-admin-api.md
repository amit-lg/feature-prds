# Quiz Admin API

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

Every request must include the employee token in the header:

```
Authorization: Bearer <employee_token>
```

Tokens are obtained from the command login endpoint. The token encodes the employee's platform and permissions.

**Required permissions** (checked server-side against the employee's permission tree):

| Action | Permission |
|--------|------------|
| View quizzes / questions | `canViewQuiz` |
| Create quiz / question | `canCreateQuiz` |
| Edit quiz / meta / options / questions / explanations / mappings | `canEditQuiz` |
| Delete quiz / question | `canDeleteQuiz` |

If the employee does not have the required permission, the server responds with `403 Forbidden`.

---

## Attachments

The following endpoints accept file uploads directly — **no separate upload step needed**:

- Create / Update question
- Add / Update option
- Set question explanation
- Set option explanation

### How to send files

Use `multipart/form-data`. Send all text fields as form fields and attach files under the field name **`files`**.

```
Content-Type: multipart/form-data

question=Which Article abolishes untouchability?
type=mcq
score=2
files=<binary: diagram.png>
files=<binary: audio-hint.mp3>
```

Up to **5 files** per request. **5 MB max** per file. Supported types: images, audio, video.

The server uploads each file to Vultr object storage and stores the resulting `[{ link, type }]` array in the `attachment` field. The stored shape is:

```json
"attachment": [
  { "link": "https://cdn.example.com/quiz/question/uuid-diagram.png", "type": "image/png" },
  { "link": "https://cdn.example.com/quiz/question/uuid-hint.mp3",    "type": "audio/mpeg" }
]
```

### Behaviour on update

**Question updates** (`PATCH /quiz/question/:id`) use a **merge** strategy:

- Sending `files` **adds** the new uploads to the existing attachment list. Previous attachments are kept unless you also pass `imagesToRemove`.
- Sending `imagesToRemove` (a JSON-encoded array of existing `link` strings) **removes** those entries from the list.
- Sending both together removes the specified entries and appends the new uploads in one step.
- Sending neither leaves `attachment` completely unchanged.

**Option and explanation updates** use a **replace** strategy — sending files overwrites the previous attachment list entirely.

### Endpoints without file uploads

All other endpoints (create quiz, set meta, mappings, fall numbers, etc.) use regular `application/json`.

---

## Base URL

```
/api/command
```

---

## Quiz

### List quizzes

```
GET /api/command/quiz
```

**Query params**

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `quizId` | integer | No | Filter by parent quiz id. Omit to get root-level quizzes as well as all. |
| `search` | string | No | Case-insensitive name search. |

**Response**

```json
[
  {
    "id": 1,
    "name": "UPSC 2025 Mock",
    "resultType": "aftersubmit",
    "accessType": "registered",
    "timeType": "duration",
    "duration": 3600,
    "order": 1,
    "isActive": true,
    "attemptType": "single",
    "quizId": null,
    "startTime": "2025-06-01T08:00:00.000Z",
    "endTime": "2025-06-01T11:00:00.000Z",
    "notified": false,
    "createdAt": "2025-05-01T10:00:00.000Z",
    "updatedAt": "2025-05-20T10:00:00.000Z",
    "Meta": { ... },
    "CourseNdPlatform": [ ... ]
  }
]
```

---

### Get quiz detail

Returns the full quiz with meta, all questions (with options, right option, explanations, fall numbers), mappings, and child quizzes.

```
GET /api/command/quiz/:id
```

**Response**

```json
{
  "id": 1,
  "name": "UPSC 2025 Mock",
  "resultType": "aftersubmit",
  "accessType": "registered",
  "timeType": "duration",
  "duration": 3600,
  "order": 1,
  "isActive": true,
  "attemptType": "single",
  "quizId": null,
  "startTime": "2025-06-01T08:00:00.000Z",
  "endTime": "2025-06-01T11:00:00.000Z",
  "Meta": {
    "id": 1,
    "quizId": 1,
    "longDescription": "Full syllabus mock test",
    "shortDescription": "3-hour timed test",
    "logo": "https://cdn.example.com/quiz-logo.png",
    "regStartTime": "2025-05-01T00:00:00.000Z",
    "regEndTime": "2025-05-31T23:59:59.000Z"
  },
  "Options": [
    { "id": 10, "key": "theme", "valueText": "dark", "valueJson": null, "type": "ui", "quizId": 1 }
  ],
  "CourseNdPlatform": [
    { "id": 5, "quizId": 1, "platformId": 2, "courseId": 3, "interface": "web", "slug": "upsc-2025" }
  ],
  "Questions": [
    {
      "id": 100,
      "question": "Who was the first Prime Minister of India?",
      "type": "mcq",
      "score": "2",
      "difficulty": 1,
      "order": 1,
      "attachment": [
        { "link": "https://cdn.example.com/quiz/question/uuid-diagram.png", "type": "image/png" }
      ],
      "Option": [
        {
          "id": 200,
          "answer": "Jawaharlal Nehru",
          "attachment": null,
          "RightOption": { "optionId": 200 },
          "Explaination": null
        },
        {
          "id": 201,
          "answer": "Sardar Patel",
          "attachment": null,
          "RightOption": null,
          "Explaination": null
        }
      ],
      "Explaination": {
        "text": "Nehru served as PM from 1947 to 1964.",
        "modelAnswer": null,
        "attachment": [{ "link": "https://cdn.example.com/quiz/explanation/uuid-clip.mp4", "type": "video/mp4" }]
      },
      "FallNumber": [
        { "questionId": 100, "fallNumberId": 7, "FallNumber": { "id": 7, "name": "Indian Polity" } }
      ]
    }
  ],
  "Quizzes": [
    { "id": 2, "name": "UPSC 2025 Mock — Section A" }
  ],
  "questionCount": 4
}
```

`questionCount` counts gradable questions, not question rows: for a question that has sub-questions (an `mcq-essay` passage with child questions attached via `questionId`), its children are counted and the parent container itself is not. A question with no children counts as itself. So a quiz with one plain MCQ and one passage containing 3 sub-questions reports `questionCount: 4`, not `2`.

`Option` arrays (here and in every other endpoint that returns question options) are ordered by `id` ascending — i.e. creation order, oldest first. `QuizQuestionOption` has no `createdAt` column, so `id` (an auto-incrementing PK) is the reliable proxy.

---

### Create quiz

```
POST /api/command/quiz
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | **Yes** | Quiz name |
| `resultType` | string | No | `never` \| `afterquiz` \| `aftersubmit` \| `collate` \| `submit-collate` |
| `accessType` | string | No | `free` \| `registered` \| `paid` \| `registered-group` |
| `timeType` | string | No | `fixed` \| `duration` \| `wait-optional` \| `wait` \| `free` |
| `duration` | integer | No | Duration in **seconds** |
| `order` | integer | No | Display order |
| `isActive` | boolean | No | Whether the quiz is live |
| `attemptType` | string | No | `single` \| `multiple` \| `repeat` \| `relay` \| `relay-optional` |
| `quizId` | integer \| null | No | Parent quiz id. `null` means root-level. |
| `startTime` | ISO 8601 string | No | e.g. `"2025-06-01T08:00:00.000Z"` |
| `endTime` | ISO 8601 string | No | e.g. `"2025-06-01T11:00:00.000Z"` |

**Example**

```json
{
  "name": "UPSC 2025 Mock",
  "resultType": "aftersubmit",
  "accessType": "registered",
  "timeType": "duration",
  "duration": 10800,
  "isActive": false,
  "attemptType": "single",
  "startTime": "2025-06-01T08:00:00.000Z",
  "endTime": "2025-06-01T11:00:00.000Z"
}
```

**Response** — the created quiz object.

---

### Update quiz

Only the fields you send are updated.

```
PATCH /api/command/quiz/:id
Content-Type: application/json
```

**Body** — same fields as Create, all optional. Additionally:

| Field | Type | Description |
|-------|------|-------------|
| `notified` | boolean | Mark whether users have been notified |

---

### Change parent quiz

Move a quiz under a different parent, or promote it to root.

```
PATCH /api/command/quiz/:id/parent
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `quizId` | integer \| null | **Yes** | New parent quiz id. Send `null` to make it root-level. |

> The server rejects circular parenting (e.g. setting a quiz's own descendant as its parent).

---

### Delete quiz

```
DELETE /api/command/quiz/:id
```

A quiz can only be deleted if it has **no child quizzes**, **no questions**, and **no platform/course mappings**. The server returns `409 Conflict` otherwise.

**Response**

```json
{ "message": "Quiz deleted successfully." }
```

---

## Quiz Meta

One meta record per quiz (upsert — creates if it doesn't exist, updates if it does).

```
PUT /api/command/quiz/:quizId/meta
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `longDescription` | string | No | Full description |
| `shortDescription` | string | No | Short tagline |
| `logo` | string | No | URL of the quiz logo |
| `regStartTime` | ISO 8601 string | No | Registration opens |
| `regEndTime` | ISO 8601 string | No | Registration closes |

**Example**

```json
{
  "shortDescription": "3-hour timed mock test",
  "logo": "https://cdn.example.com/quiz-logo.png",
  "regStartTime": "2025-05-01T00:00:00.000Z",
  "regEndTime": "2025-05-31T23:59:59.000Z"
}
```

---

## Quiz Meta Options

Key-value configuration pairs attached to a quiz (e.g. theme, rules, pass marks).

### Add meta option

```
POST /api/command/quiz/:quizId/meta-option
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | string | **Yes** | Option key |
| `valueText` | string | No | Plain text value |
| `valueJson` | any | No | JSON value (object, array, number, boolean) |
| `type` | string | No | Category tag for the option |

**Example**

```json
{ "key": "passMark", "valueText": "50", "type": "scoring" }
```

---

### Update meta option

```
PATCH /api/command/quiz/meta-option/:id
Content-Type: application/json
```

**Body** — same fields as Add, all optional.

---

### Delete meta option

```
DELETE /api/command/quiz/meta-option/:id
```

---

## Quiz Platform / Course Mapping

Controls which platforms (and optionally which courses) a quiz appears under.

### Add mapping

```
POST /api/command/quiz/mapping
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `quizId` | integer | **Yes** | |
| `platformId` | integer | **Yes** | |
| `courseId` | integer \| null | No | Leave out or send `null` for platform-wide |
| `interface` | string | No | e.g. `"web"`, `"mobile"` |
| `slug` | string | No | URL slug for the quiz on this platform |

**Example**

```json
{
  "quizId": 1,
  "platformId": 2,
  "courseId": 3,
  "slug": "upsc-2025-mock"
}
```

Duplicate mappings (same quizId + platformId + courseId) return `409 Conflict`.

---

### Remove mapping

```
DELETE /api/command/quiz/mapping/:id
```

---

## Questions

### Search questions

```
GET /api/command/quiz/question
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `quizId` | integer | Filter by quiz |
| `fallNumberId` | integer | Filter questions tagged with this fall number |
| `courseId` | integer | Filter questions whose fall numbers are mapped to this course |
| `search` | string | Case-insensitive search within question text |
| `type` | string | `mcq` \| `essay` \| `mcq-essay` |
| `questionCode` | string | Case-insensitive contains search on `questionCode` |
| `page` | integer | 0-indexed, 10 results per page. Defaults to `0`. |

Results are ordered by `order ASC, id ASC`. Each item includes options (with right-option and per-option explanation) and fall numbers (with linked courses). Options within each question are ordered by creation (`id ASC`) — see the note under [Get quiz detail](#get-quiz-detail).

**Example**

```
GET /api/command/quiz/question?quizId=1&search=nehru&page=0
GET /api/command/quiz/question?fallNumberId=3
GET /api/command/quiz/question?courseId=2&questionCode=UPSC
```

---

### Get individual question

Returns a single question with options (right-option + per-option explanation), question explanation, fall numbers, and direct child sub-questions.

```
GET /api/command/quiz/question/:id
```

Options are ordered by creation (`id ASC`) — see the note under [Get quiz detail](#get-quiz-detail).

Returns `404 Not Found` if the question does not exist.

---

### List questions for a quiz

```
GET /api/command/quiz/:quizId/question
```

Returns all questions for a specific quiz ordered by `order ASC, id ASC`. Options within each question are ordered by creation (`id ASC`) — see the note under [Get quiz detail](#get-quiz-detail).

---

## Question Reports (Dashboard)

### Get unresolved report count

Used for the dashboard badge. Returns the total number of quiz question reports and how many are still unresolved.

```
GET /api/command/quiz/report/stats
```

**Response**

```json
{ "total": 30, "unresolved": 7 }
```

---

### List unresolved reports

Fetch all unresolved quiz question reports with their question details. Click the unresolved count on the dashboard to call this endpoint. Returns 20 per page.

```
GET /api/command/quiz/report
```

**Query params**

| Param | Type | Description |
|-------|------|-------------|
| `page` | integer | 0-indexed page number. Defaults to `0`. |

**Response** — array of report objects, newest first

```json
[
  {
    "questionId": 100,
    "userId": 42,
    "reason": "Option B should be correct, not A",
    "tag": null,
    "isResolved": null,
    "createdAt": "2025-06-01T10:00:00.000Z",
    "updatedAt": "2025-06-01T10:00:00.000Z",
    "Question": {
      "id": 100,
      "question": "Who was the first PM of India?",
      "type": "mcq",
      "Option": [
        { "id": 200, "answer": "Nehru", "RightOption": { "optionId": 200 } },
        { "id": 201, "answer": "Patel", "RightOption": null }
      ],
      "Explaination": { "text": "Nehru served from 1947–1964.", "modelAnswer": null, "attachment": null }
    },
    "User": {
      "id": 42, "fname": "Rahul", "lname": "Singh",
      "email": "rahul@example.com", "phone": "9876543210"
    }
  }
]
```

---

### Resolve a report

Mark a single quiz question report as resolved. Optionally store structured remarks in `fieldJson`. Records which employee resolved it.

```
PATCH /api/command/quiz/report/:userId/:questionId/resolve
Content-Type: application/json
```

**Path params**

| Param | Description |
|-------|-------------|
| `userId` | The user who filed the report |
| `questionId` | The question the report is about |

**Body** — all optional

```json
{
  "fieldJson": {
    "remark": "Confirmed — the key was wrong, now corrected.",
    "action": "right_option_changed"
  }
}
```

Send an empty body `{}` to resolve without remarks.

**Response** — the updated report object with `isResolved: true`, `employeeId` set to the resolving employee, and `fieldJson` stored.

Returns `404` if the report does not exist.

---

### Get question stats

Returns how many users answered a quiz question correctly, wrongly, or left it ungraded. Also includes report counts.

```
GET /api/command/quiz/question/:id/stats
```

**Response**

```json
{
  "questionId": 100,
  "total": 400,
  "correct": 280,
  "wrong": 110,
  "ungraded": 10,
  "reportCount": 5,
  "unresolvedReports": 2
}
```

| Field | Meaning |
|-------|---------|
| `total` | Submitted answers for this question |
| `correct` | MCQ: answers where the selected option is the right option. Essay: answers where `isCorrect = true`. |
| `wrong` | MCQ: answers where a non-right option was selected. Essay: answers where `isCorrect = false`. |
| `ungraded` | Submitted but not yet graded |
| `reportCount` | Total reports filed against this question |
| `unresolvedReports` | Reports not yet marked as resolved |

---

## Questions

### List questions for a quiz

```
GET /api/command/quiz/:quizId/question
```

Returns questions ordered by `order ASC, id ASC`, each with its options (including right-option and explanation per option), question explanation, and linked fall numbers.

---

### Create question

```
POST /api/command/quiz/question
Content-Type: multipart/form-data
```

Send all fields as form fields. Optionally attach up to 5 files under the field name `files`.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `question` | string | **Yes** | Question text (HTML allowed) |
| `quizId` | integer \| null | No | Quiz to attach to |
| `score` | string | No | Marks for a correct answer e.g. `"2"` |
| `averageTime` | string | No | Expected time in seconds e.g. `"60"` |
| `difficulty` | integer | No | 1 (easy) – 5 (very hard) |
| `order` | integer | No | Display order within the quiz |
| `canShuffle` | boolean | No | Whether option order can be shuffled |
| `questionId` | integer \| null | No | Parent question id (for sub-questions in `mcq-essay`). Sending this clears `quizId` — a sub-question belongs to its parent question, not directly to the quiz. |
| `questionCode` | string | No | Internal reference code |
| `type` | string | No | `mcq` \| `essay` \| `mcq-essay` |
| `attribute` | string | No | Custom tag / attribute |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

**Example (curl)**

```bash
curl -X POST /api/command/quiz/question \
  -H "Authorization: Bearer <token>" \
  -F "question=Which Article abolishes untouchability?" \
  -F "type=mcq" \
  -F "score=2" \
  -F "difficulty=2" \
  -F "order=1" \
  -F "files=@diagram.png" \
  -F "files=@audio-hint.mp3"
```

**Response** — the created question object.

---

### Update question

```
PATCH /api/command/quiz/question/:id
Content-Type: multipart/form-data
```

Same fields as Create, all optional. Additionally:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `imagesToRemove` | JSON string | No | A JSON-encoded array of existing attachment `link` URLs to remove. e.g. `'["https://cdn.example.com/quiz/question/uuid-diagram.png"]'` |

Attachment update follows a **merge** strategy — see [Behaviour on update](#behaviour-on-update).

**Example (curl) — swap one image for a new one**

```bash
curl -X PATCH /api/command/quiz/question/100 \
  -H "Authorization: Bearer <token>" \
  -F "imagesToRemove=[\"https://cdn.example.com/quiz/question/uuid-old.png\"]" \
  -F "files=@new-diagram.png"
```

---

### Move question to a different quiz / parent question

```
PATCH /api/command/quiz/question/:id/parent
Content-Type: application/json
```

A question is either a direct child of a quiz (`quizId`) or a sub-question of another question (`questionId`) — never both. Send whichever one applies; the server clears the other field automatically so the question doesn't end up listed twice (once at the quiz's top level, once nested under the parent question).

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `quizId` | integer \| null | No | New quiz id to attach directly to. Sending this clears `questionId`. `null` unassigns from any quiz. |
| `questionId` | integer \| null | No | New parent question id to attach under. Sending a non-null value clears `quizId`. `404` if it doesn't reference an existing question. |

If `questionId` is non-null, it wins and `quizId` is set to `null` regardless of what was sent for `quizId`.

---

### Delete question

```
DELETE /api/command/quiz/question/:id
```

A question can only be deleted if it has **no options**. Delete all options first.

---

## Question Options

### Add option

```
POST /api/command/quiz/question/:questionId/option
Content-Type: multipart/form-data
```

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `answer` | string | **Yes** | Option text (HTML allowed) |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

---

### Update option

```
PATCH /api/command/quiz/question/option/:id
Content-Type: multipart/form-data
```

**Fields** — same as Add, all optional. Sending `files` replaces the option's `attachment`.

---

### Delete option

```
DELETE /api/command/quiz/question/option/:id
```

> Cannot delete the option that is currently marked as the correct answer. Change the right option first.

---

## Correct Answer (Right Option)

### Set correct option

```
PUT /api/command/quiz/question/:questionId/right-option
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `optionId` | integer | **Yes** | The option to mark as correct. Must belong to this question. |

This is an upsert — calling it again with a different `optionId` replaces the previous correct answer.

---

### Remove correct option mark

```
DELETE /api/command/quiz/question/:questionId/right-option
```

---

## Explanations

### Set question explanation

```
PUT /api/command/quiz/question/:questionId/explanation
Content-Type: multipart/form-data
```

Upsert — creates if none exists, updates if it does.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | **Yes** | Explanation text (HTML allowed) |
| `modelAnswer` | string | No | Model answer text |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

---

### Set option explanation

```
PUT /api/command/quiz/question/option/:optionId/explanation
Content-Type: multipart/form-data
```

Upsert — creates if none exists, updates if it does.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | **Yes** | Why this option is correct or incorrect |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

---

## Fall Numbers (Subject Tags)

Links a question to a subject fall number for filtering and analytics.

### Toggle fall number

Single endpoint that **adds the link if it doesn't exist, or removes it if it does**.

```
POST /api/command/quiz/question/:questionId/fall-number
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `fallNumberId` | integer | **Yes** | Fall number id to toggle |

**Response**

```json
{ "action": "added", "questionId": 100, "fallNumberId": 7 }
```

or

```json
{ "action": "removed", "questionId": 100, "fallNumberId": 7 }
```

Use `action` to update your UI state without a separate refetch.

---

## Quiz Registrations & Results (Dashboard)

### List registrations for a quiz

Returns everyone registered for a quiz (`QuizToUser` rows), each with their attempt(s) — marks, correct/wrong/ungraded counts, and any cheating incidents. This powers a single dashboard screen: "who registered → did they attempt → what did they score → did they cheat."

```
GET /api/command/quiz/:quizId/registrations
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `search` | string | Case-insensitive search across the registered user's `fname`, `lname`, `email`, `phone` |
| `groupId` | integer | Filter to registrations under a specific `QuizGroup` |
| `onlyCheating` | boolean | Only return users who have at least one `QuizUserCheating` incident on any attempt for this quiz |
| `page` | integer | 0-indexed, 20 results per page. Defaults to `0`. |

**Response**

```json
{
  "quizId": 1,
  "page": 0,
  "pageSize": 20,
  "total": 42,
  "maxMarks": 100,
  "registrations": [
    {
      "quizId": 1,
      "userId": 42,
      "fieldJson": null,
      "groupId": 3,
      "groupName": "Team Alpha",
      "registeredAt": "2025-06-01T10:00:00.000Z",
      "updatedAt": "2025-06-01T10:00:00.000Z",
      "user": {
        "id": 42,
        "fname": "Rahul",
        "lname": "Singh",
        "email": "rahul@example.com",
        "phone": "9876543210"
      },
      "attempts": [
        {
          "attemptId": 501,
          "hasSubmitted": true,
          "timeTaken": 3400,
          "marks": 82,
          "maxMarks": 100,
          "correctCount": 41,
          "wrongCount": 5,
          "ungradedCount": 2,
          "cheating": [
            {
              "id": 9,
              "questionId": 118,
              "offense": "tab_switch",
              "createdAt": "2025-06-01T10:42:00.000Z"
            }
          ],
          "createdAt": "2025-06-01T10:00:12.000Z",
          "updatedAt": "2025-06-01T11:17:00.000Z"
        }
      ],
      "hasAttempted": true,
      "hasCheated": true
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `maxMarks` | Total possible marks for the quiz — sum of every `QuizQuestion.score` under `quizId` (`score` is stored as a string, parsed to a number; unparsable/missing scores count as `0`) |
| `registrations[].attempts` | One entry per `UserQuizAttempt` the user has for this quiz — empty array if they registered but never started (`attemptType` of `multiple`/`repeat`/`relay` can produce more than one) |
| `attempts[].marks` | Sum of `QuizQuestion.score` for answers where `isCorrect = true` on that attempt |
| `attempts[].correctCount` / `wrongCount` / `ungradedCount` | Counts of `UserQuizAnswer` rows on that attempt where `isCorrect` is `true` / `false` / `null` |
| `attempts[].cheating` | Raw `QuizUserCheating` rows tied to that attempt (`id`, `questionId`, `offense`, `createdAt`) |
| `hasAttempted` | `true` if the user has at least one `UserQuizAttempt` row for this quiz |
| `hasCheated` | `true` if any of the user's attempts has at least one cheating incident |

**Notes:**
- Requires `canViewQuiz` permission, same as the rest of the quiz admin reads.
- `onlyCheating=true` filters at the registration level, before pagination — so `total`/`page` reflect only cheating users when the flag is set.
- A registered user with no attempts still appears (with `attempts: []`, `hasAttempted: false`) — useful for a "registered but never showed up" view.

---

## Common Error Responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Validation failed, circular parent, or business rule violation |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Employee does not have the required permission |
| `404 Not Found` | The requested resource does not exist |
| `409 Conflict` | Duplicate mapping, deleting a resource that still has dependents, etc. |

---

## Typical Flows

### Create a quiz end-to-end

```
1. POST   /api/command/quiz                              → get quizId
2. PUT    /api/command/quiz/:quizId/meta                 → set description & logo
3. POST   /api/command/quiz/mapping                      → attach to a platform/course
4. POST   /api/command/quiz/question         (multipart) → create question with optional files, get questionId
5. POST   /api/command/quiz/question/:questionId/option  (multipart) → add option A, get optionId
6. POST   /api/command/quiz/question/:questionId/option  (multipart) → add option B
7. PUT    /api/command/quiz/question/:questionId/right-option        → mark option A correct
8. PUT    /api/command/quiz/question/:questionId/explanation (multipart) → add explanation with optional files
9. POST   /api/command/quiz/question/:questionId/fall-number         → tag with subject
10. PATCH /api/command/quiz/:quizId                                  → set isActive: true to publish
```

### Edit a question's correct answer

```
PUT  /api/command/quiz/question/:questionId/right-option
Body: { "optionId": <newOptionId> }
```

The server replaces the old correct answer automatically.

### Move a child quiz under a new parent

```
PATCH /api/command/quiz/:id/parent
Body: { "quizId": <newParentId> }
```

Sending `null` promotes it to root level.

---
---

<!--
  Copy everything between this comment and the matching one at the bottom
  into a new GitHub issue (paste as-is, GitHub renders the markdown).
-->

## Quiz Registrations & Results screen — API

**Type:** Sub-issue · Backend
**Status:** Implemented — pending review/QA

### Summary

Admin dashboard needs a single screen showing, per quiz: who registered (`QuizToUser`), what they scored once they've attempted it, and who has been flagged for cheating (`QuizUserCheating`). Currently there is no endpoint that joins these three — registrations, marks, and cheating all have to be checked separately.

### Endpoint

```
GET /api/command/quiz/:quizId/registrations
```

Auth: `EmployeeAuthGuard`, permission `canViewQuiz` (matches all other quiz-admin read endpoints).

**Query params**

| Param | Type | Description |
|-------|------|-------------|
| `search` | string | Search registered user's fname/lname/email/phone |
| `groupId` | integer | Filter to a specific `QuizGroup` |
| `onlyCheating` | boolean | Only users with ≥1 cheating incident on this quiz |
| `page` | integer | 0-indexed, 20 per page |

**Response shape**

```json
{
  "quizId": 1,
  "page": 0,
  "pageSize": 20,
  "total": 42,
  "maxMarks": 100,
  "registrations": [
    {
      "quizId": 1,
      "userId": 42,
      "fieldJson": null,
      "groupId": 3,
      "groupName": "Team Alpha",
      "registeredAt": "2025-06-01T10:00:00.000Z",
      "updatedAt": "2025-06-01T10:00:00.000Z",
      "user": { "id": 42, "fname": "Rahul", "lname": "Singh", "email": "rahul@example.com", "phone": "9876543210" },
      "attempts": [
        {
          "attemptId": 501,
          "hasSubmitted": true,
          "timeTaken": 3400,
          "marks": 82,
          "maxMarks": 100,
          "correctCount": 41,
          "wrongCount": 5,
          "ungradedCount": 2,
          "cheating": [
            { "id": 9, "questionId": 118, "offense": "tab_switch", "createdAt": "2025-06-01T10:42:00.000Z" }
          ],
          "createdAt": "2025-06-01T10:00:12.000Z",
          "updatedAt": "2025-06-01T11:17:00.000Z"
        }
      ],
      "hasAttempted": true,
      "hasCheated": true
    }
  ]
}
```

Full field-by-field description: see the "Quiz Registrations & Results (Dashboard)" section in `docs/quiz-admin-api.md`.

### Design notes

- **Marks are computed, not stored.** No existing table stores a per-attempt total score — `marks` is derived per attempt by summing `QuizQuestion.score` (a string field, parsed with `parseFloat`, `0` on failure) across `UserQuizAnswer` rows where `isCorrect = true`. `maxMarks` is the sum of `score` across every question in the quiz.
- **A user can have multiple attempts** for quizzes with `attemptType` of `multiple`/`repeat`/`relay` — `attempts` is an array, not a single object, and a registered user who never started shows `attempts: []`, `hasAttempted: false`.
- **Cheating is sourced from `QuizUserCheating`**, joined via `UserQuizAttempt` (no direct FK from `QuizToUser`). `onlyCheating` pre-filters registrations to users with ≥1 cheating row across any of their attempts on this quiz, applied before pagination so `total` reflects the filtered count.

### Acceptance Criteria

- [x] `GET /api/command/quiz/:quizId/registrations` returns paginated `QuizToUser` rows for the given quiz, including full user info and quiz group name.
- [x] Each registration includes all of the user's `UserQuizAttempt` rows for that quiz, each with computed `marks`, `correctCount`, `wrongCount`, `ungradedCount`.
- [x] Each attempt includes its `QuizUserCheating` incidents (question id, offense, timestamp).
- [x] `search`, `groupId`, `onlyCheating`, `page` query params all work and are combinable.
- [x] Endpoint requires `canViewQuiz` permission and returns `403` without it, `404` if the quiz doesn't exist.
- [ ] Manually verified against a quiz with: multiple registrations, at least one multi-attempt user, and at least one cheating incident.

### Files touched

- `src/quiz/dto/admin/get-quiz-registrations.dto.ts` (new)
- `src/quiz/quiz.service.ts` — `adminGetQuizRegistrations`
- `src/command/command.controller.ts` — `GET quiz/:quizId/registrations`
- `docs/quiz-admin-api.md` — API documentation

<!-- end GitHub issue paste -->
