# Practice Admin API

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

Every request must include the employee token in the header:

```
Authorization: Bearer <employee_token>
```

**Required permissions** (checked server-side against the employee's permission tree):

| Action | Permission |
|--------|------------|
| View questions / stats | `canViewPractice` |
| Create questions | `canCreatePractice` |
| Edit questions / options / explanations / fall numbers / right option | `canEditPractice` |
| Delete questions | `canDeletePractice` |

If the employee does not have the required permission the server responds with `403 Forbidden`.

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

question=Which planet is closest to the Sun?
type=mcq
score=1
files=<binary: diagram.png>
files=<binary: audio-hint.mp3>
```

Up to **5 files** per request. **5 MB max** per file. Supported types: images, audio, video.

The server uploads each file to Vultr object storage and stores the resulting `[{ link, type }]` array in the `attachment` field. The stored shape is:

```json
"attachment": [
  { "link": "https://cdn.example.com/practice/question/uuid-diagram.png", "type": "image/png" },
  { "link": "https://cdn.example.com/practice/question/uuid-hint.mp3",    "type": "audio/mpeg" }
]
```

### Behaviour on update

**Question updates** (`PATCH /practice/question/:id`) use a **merge** strategy:

- Sending `files` **adds** the new uploads to the existing attachment list. The previous attachments are kept unless you also pass `imagesToRemove`.
- Sending `imagesToRemove` (a JSON-encoded array of existing `link` strings) **removes** those entries from the list.
- Sending both together replaces the removed entries with the new uploads in one step.
- Sending neither leaves `attachment` completely unchanged.

**Option and explanation updates** use a **replace** strategy — sending files overwrites the previous attachment list entirely.

### Endpoints without file uploads

All other endpoints (fall numbers, right option, parent change, etc.) use regular `application/json`.

---

## Base URL

```
/api/command
```

---

## Questions

### List practice questions

```
GET /api/command/practice/question
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `fallNumberId` | integer | Filter questions tagged with this fall number |
| `courseId` | integer | Filter questions whose fall numbers are mapped to this course |
| `search` | string | Case-sensitive search within question text |
| `type` | string | `mcq` \| `essay` \| `mcq-essay` |
| `questionCode` | string | Case-insensitive contains search on the `questionCode` field |
| `page` | integer | Page number (0-indexed). Returns 10 results per page. Defaults to `0`. |

Results are ordered by `priority ASC, id ASC`.

**Response**

Each item includes:
- All question fields including `createdAt`
- `Option[]` — each option with its `RightOption` and `Explaination`
- `Explaination` — question-level explanation
- `FallNumber[]` — fall number tags with their linked courses

```json
[
  {
    "id": 1,
    "question": "What is the capital of France?",
    "type": "mcq",
    "score": "1",
    "averageTime": "30",
    "difficulty": 1,
    "priority": 1,
    "attribute": null,
    "questionCode": "GEO-001",
    "questionId": null,
    "attachment": [
      { "link": "https://cdn.example.com/practice/question/uuid-map.png", "type": "image/png" }
    ],
    "createdAt": "2025-05-01T10:00:00.000Z",
    "updatedAt": "2025-05-20T10:00:00.000Z",
    "Option": [
      {
        "id": 10,
        "answer": "Paris",
        "attachment": null,
        "RightOption": { "optionId": 10 },
        "Explaination": { "optionId": 10, "text": "Paris is the capital of France.", "attachment": null }
      },
      {
        "id": 11,
        "answer": "Berlin",
        "attachment": null,
        "RightOption": null,
        "Explaination": null
      }
    ],
    "Explaination": {
      "questionId": 1,
      "text": "France's capital has been Paris since the late 10th century.",
      "modelAnswer": null,
      "attachment": [{ "link": "https://cdn.example.com/practice/explanation/uuid-history.mp3", "type": "audio/mpeg" }]
    },
    "FallNumber": [
      {
        "questionId": 1,
        "fallNumberId": 3,
        "FallNumber": {
          "id": 3,
          "number": "GEO-101",
          "Course": [
            {
              "id": 7,
              "fallId": 3,
              "courseId": 2,
              "Course": { "id": 2, "name": "World Geography" }
            }
          ]
        }
      }
    ]
  }
]
```

---

### Get single question detail

```
GET /api/command/practice/question/:id
```

Returns the same shape as a single item from the list, plus a `Questions` array of direct child (sub-)questions:

```json
{
  "id": 1,
  "question": "...",
  "Questions": [
    { "id": 5, "question": "Sub-question text", "type": "mcq" }
  ],
  ...
}
```

---

### Create a question

```
POST /api/command/practice/question
Content-Type: multipart/form-data
```

Send all fields as form fields. Optionally attach up to 5 files under the field name `files`.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `question` | string | **Yes** | Question text (HTML allowed) |
| `type` | string | No | `mcq` \| `essay` \| `mcq-essay` |
| `score` | string | No | Marks for a correct answer e.g. `"1"` |
| `averageTime` | string | No | Expected time in seconds e.g. `"45"` |
| `difficulty` | integer | No | 1 (easy) – 5 (very hard) |
| `priority` | integer | No | Lower = shown first in lists |
| `questionId` | integer \| null | No | Parent question id for sub-questions (`mcq-essay`). `null` = root. |
| `questionCode` | string | No | Internal reference code e.g. `"GEO-001"` |
| `attribute` | string | No | Custom tag |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

**Example (curl)**

```bash
curl -X POST /api/command/practice/question \
  -H "Authorization: Bearer <token>" \
  -F "question=Which planet is closest to the Sun?" \
  -F "type=mcq" \
  -F "score=1" \
  -F "difficulty=1" \
  -F "priority=10" \
  -F "questionCode=SCI-042" \
  -F "files=@solar-system.png"
```

**Response** — the created question object.

---

### Update a question

Only the fields you send are updated.

```
PATCH /api/command/practice/question/:id
Content-Type: multipart/form-data
```

Same fields as Create, all optional. Additionally:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `imagesToRemove` | JSON string | No | A JSON-encoded array of existing attachment `link` URLs to remove. e.g. `'["https://cdn.example.com/…/uuid-map.png"]'` |

Attachment update follows a **merge** strategy — see [Behaviour on update](#behaviour-on-update).

**Example (curl) — swap one image for a new one**

```bash
curl -X PATCH /api/command/practice/question/1 \
  -H "Authorization: Bearer <token>" \
  -F "imagesToRemove=[\"https://cdn.example.com/practice/question/uuid-old.png\"]" \
  -F "files=@new-diagram.png"
```

---

### Change parent question

Move a sub-question under a different parent, or promote it to root.

```
PATCH /api/command/practice/question/:id/parent
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `questionId` | integer \| null | **Yes** | New parent question id. Send `null` to make it root-level. |

---

### Delete a question

```
DELETE /api/command/practice/question/:id
```

A question can only be deleted if it has **no options**. Delete all options first, otherwise the server returns `409 Conflict`.

**Response**

```json
{ "message": "Practice question deleted." }
```

---

### Get question stats

Returns how many users answered this question correctly, wrongly, or left it ungraded. Also includes report counts for this question.

```
GET /api/command/practice/question/:id/stats
```

**Response**

```json
{
  "questionId": 1,
  "total": 500,
  "correct": 310,
  "wrong": 140,
  "ungraded": 50,
  "reportCount": 8,
  "unresolvedReports": 3
}
```

| Field | Meaning |
|-------|---------|
| `total` | Submitted answers for this question |
| `correct` | MCQ: answers where the selected option is the right option. Essay / mcq-essay: answers where `isCorrect = true`. |
| `wrong` | MCQ: answers where a non-right option was selected. Essay / mcq-essay: answers where `isCorrect = false`. |
| `ungraded` | Submitted but correctness not yet determined (essay answers pending manual grading) |
| `reportCount` | Total reports filed against this question |
| `unresolvedReports` | Reports not yet marked as resolved |

---

---

## Question Reports (Dashboard)

### Get unresolved report count

Used for the dashboard badge. Returns the total number of practice question reports and how many are still unresolved.

```
GET /api/command/practice/report/stats
```

**Response**

```json
{ "total": 42, "unresolved": 15 }
```

---

### List unresolved reports

Fetch all unresolved practice question reports with their question details. Click the unresolved count on the dashboard to call this endpoint. Returns 20 per page.

```
GET /api/command/practice/report
```

**Query params**

| Param | Type | Description |
|-------|------|-------------|
| `page` | integer | 0-indexed page number. Defaults to `0`. |

**Response** — array of report objects, newest first

```json
[
  {
    "questionId": 1,
    "userId": 42,
    "reason": "Wrong answer marked as correct",
    "tag": null,
    "isResolved": null,
    "createdAt": "2025-06-01T10:00:00.000Z",
    "updatedAt": "2025-06-01T10:00:00.000Z",
    "Question": {
      "id": 1,
      "question": "What is the capital of France?",
      "type": "mcq",
      "Option": [
        { "id": 10, "answer": "Paris", "RightOption": { "optionId": 10 } },
        { "id": 11, "answer": "Berlin", "RightOption": null }
      ],
      "Explaination": { "text": "...", "modelAnswer": null, "attachment": null }
    },
    "User": {
      "id": 42, "fname": "Rahul", "lname": "Singh",
      "email": "rahul@example.com", "phone": "9876543210"
    }
  }
]
```

### Resolve a report

Mark a single practice question report as resolved. Optionally store structured remarks in `fieldJson`. Records which employee resolved it.

```
PATCH /api/command/practice/report/:userId/:questionId/resolve
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
    "remark": "Verified — option A is correct, question text updated.",
    "action": "question_updated"
  }
}
```

Send an empty body `{}` to resolve without remarks.

**Response** — the updated report object with `isResolved: true`, `employeeId` set to the resolving employee, and `fieldJson` stored.

Returns `404` if the report does not exist.

---

## Practice Student Dashboard

Three endpoints that give a full view of how students are performing on practice across a course hierarchy.

All three share the same filter parameters:

| Param | Type | Description |
|-------|------|-------------|
| `courseId` | integer | **Required.** Top-level course to scope the data. |
| `childCourseId` | integer | Narrow to a child course. |
| `startDate` | ISO string | Include only attempts on or after this date. |
| `endDate` | ISO string | Include only attempts on or before this date. |

The effective course used for filtering is the most-specific scope provided: `childCourseId` → `courseId`.

---

### Summary

```
GET /api/command/practice/dashboard
```

Returns aggregate stats for the whole platform across the scoped course.

**Response**

```json
{
  "courseId": 5,
  "childCourses": [
    { "id": 10, "name": "Batch Nov 2025", "abbr": "NOV25" }
  ],
  "totalEnrolled": 1200,
  "studentsAttempted": 750,
  "studentsNeverAttempted": 450,
  "totalAttempts": 4500,
  "totalAnswered": 150000,
  "overallCorrect": 85000,
  "overallWrong": 55000,
  "overallUngraded": 10000,
  "studentsWithFirstTimeCorrect": 650,
  "studentsWithFirstTimeWrong": 400
}
```

| Field | Meaning |
|-------|---------|
| `childCourses` | Direct children of the effective course — use these ids to drill down via `childCourseId` or `sessionId`. |
| `totalEnrolled` | Students with an active `UserToCourse` record for the effective course. |
| `studentsAttempted` | Distinct students who started at least one practice attempt. |
| `studentsNeverAttempted` | `totalEnrolled − studentsAttempted` (floor 0). |
| `totalAttempts` | Total practice sessions created in the scope. |
| `totalAnswered` | Individual questions answered across all sessions. |
| `overallCorrect` | MCQ: selected option was the right option. Essay: grader marked `isCorrect = true`. |
| `overallWrong` | MCQ: non-right option selected. Essay: `isCorrect = false`. |
| `overallUngraded` | Submitted but correctness not yet determined. |
| `studentsWithFirstTimeCorrect` | Students who answered ≥ 1 question correctly on their very first attempt at it. |
| `studentsWithFirstTimeWrong` | Students who answered ≥ 1 question incorrectly on their very first attempt at it. |

---

### Per-student breakdown

```
GET /api/command/practice/dashboard/students
```

Additional params:

| Param | Type | Description |
|-------|------|-------------|
| `search` | string | Case-insensitive match on student first name, last name, email, or phone. |
| `page` | integer | 0-indexed page (20 students per page). Defaults to `0`. |

Returns 20 students per page, ordered by most-recently-active first.

**Response** — array of student rows

```json
[
  {
    "user": {
      "id": 42,
      "fname": "Rahul",
      "lname": "Singh",
      "email": "rahul@example.com",
      "phone": "9876543210"
    },
    "totalAttempts": 5,
    "totalAnswered": 120,
    "correct": 80,
    "wrong": 30,
    "ungraded": 10,
    "firstTimeCorrect": 60,
    "firstTimeWrong": 25,
    "lastAttemptAt": "2025-06-01T10:00:00.000Z"
  }
]
```

| Field | Meaning |
|-------|---------|
| `totalAttempts` | Practice sessions the student started (submitted or not). |
| `totalAnswered` | Questions submitted by the student in the scope. |
| `correct` | Questions answered correctly (cumulative across all attempts). |
| `wrong` | Questions answered incorrectly (cumulative). |
| `ungraded` | Submitted but not yet graded. |
| `firstTimeCorrect` | Number of questions this student got right on their **first-ever** attempt at each question. |
| `firstTimeWrong` | Number of questions this student got wrong on their **first-ever** attempt at each question. |
| `lastAttemptAt` | Timestamp of their most recent practice session. |

---

### Per-question breakdown

```
GET /api/command/practice/dashboard/questions
```

Additional params:

| Param | Type | Description |
|-------|------|-------------|
| `fallNumberId` | integer | Limit to questions tagged with this fall number (subject). |
| `page` | integer | 0-indexed page (20 questions per page). Defaults to `0`. |

Returns 20 questions per page ordered by `priority ASC, id ASC`. Only root-level questions (no parent) are returned.

**Response** — array of question rows

```json
[
  {
    "id": 1,
    "questionCode": "GEO-001",
    "question": "What is the capital of France?",
    "type": "mcq",
    "difficulty": 2,
    "priority": 10,
    "totalStudents": 450,
    "firstTimeCorrect": 280,
    "firstTimeWrong": 150,
    "firstTimeUngraded": 20
  }
]
```

| Field | Meaning |
|-------|---------|
| `totalStudents` | Unique students who answered this question in the scope. |
| `firstTimeCorrect` | Students who answered it correctly on their **first-ever** attempt. |
| `firstTimeWrong` | Students who answered it incorrectly on their first attempt. |
| `firstTimeUngraded` | Students whose first attempt was an unanswered/essay slot (pending grading). |

---

## User Practice Stats

Check how many practice questions a specific user has attempted, by looking them up with their email or phone number.

```
GET /api/command/practice/user/stats
```

**Query params** — provide at least one

| Param | Type | Description |
|-------|------|-------------|
| `email` | string | User's registered email |
| `phone` | string | User's registered phone |

If neither is provided the server returns `400 Bad Request`.
If no user matches, the server returns `404 Not Found`.

**Response**

```json
{
  "user": {
    "id": 42,
    "fname": "Rahul",
    "lname": "Singh",
    "email": "rahul@example.com",
    "phone": "9876543210"
  },
  "totalAttempts": 12,
  "totalAnswered": 340,
  "correct": 210,
  "wrong": 95,
  "ungraded": 35
}
```

| Field | Meaning |
|-------|---------|
| `totalAttempts` | Number of practice sessions the user started |
| `totalAnswered` | Total questions submitted across all sessions |
| `correct` | Questions answered correctly |
| `wrong` | Questions answered incorrectly |
| `ungraded` | Submitted but not yet graded |

---

## Options

### Add an option to a question

```
POST /api/command/practice/question/:questionId/option
Content-Type: multipart/form-data
```

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `answer` | string | **Yes** | Option text (HTML allowed) |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

**Response** — the created option object.

---

### Update an option

```
PATCH /api/command/practice/question/option/:id
Content-Type: multipart/form-data
```

Same fields as Add, all optional. Sending `files` replaces the option's `attachment`.

---

### Delete an option

```
DELETE /api/command/practice/question/option/:id
```

> Cannot delete the option that is currently marked as the correct answer. Change the right option first — the server returns `409 Conflict` otherwise.

---

## Correct Answer (Right Option)

### Set correct option

```
PUT /api/command/practice/question/:questionId/right-option
Content-Type: application/json
```

This is an **upsert** — calling it again with a different `optionId` replaces the previous correct answer automatically.

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `optionId` | integer | **Yes** | The option to mark as correct. Must belong to this question. |

**Example**

```json
{ "optionId": 10 }
```

---

### Remove correct option mark

```
DELETE /api/command/practice/question/:questionId/right-option
```

Returns `404` if no correct option was set.

---

## Explanations

### Set question explanation

```
PUT /api/command/practice/question/:questionId/explanation
Content-Type: multipart/form-data
```

**Upsert** — creates if none exists, updates if it does.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | **Yes** | Explanation text (HTML allowed) |
| `modelAnswer` | string | No | Model answer text |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

---

### Set option explanation

```
PUT /api/command/practice/question/option/:optionId/explanation
Content-Type: multipart/form-data
```

**Upsert** — creates if none exists, updates if it does.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | **Yes** | Why this option is correct or incorrect |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

---

## Fall Numbers (Subject Tags)

A fall number tags a question with a subject, which is also mapped to one or more courses via `FallNumberToCourse`. This is what drives filtering by `courseId` in the list endpoint.

### Toggle fall number

Single endpoint — **adds the link if it doesn't exist, removes it if it does**.

```
POST /api/command/practice/question/:questionId/fall-number
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `fallNumberId` | integer | **Yes** | Fall number id to toggle |

**Response**

```json
{ "action": "added", "questionId": 1, "fallNumberId": 3 }
```

or

```json
{ "action": "removed", "questionId": 1, "fallNumberId": 3 }
```

Use `action` to update your UI state without a refetch.

---

## Common Error Responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Validation failed, self-parenting, or missing required query param |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Employee does not have the required permission |
| `404 Not Found` | The requested resource does not exist |
| `409 Conflict` | Deleting a question that still has options, or deleting the marked correct option |

---

## Typical Flows

### Create a question end-to-end

```
1. POST  /api/command/practice/question  (multipart)                         → get questionId
2. POST  /api/command/practice/question/:questionId/option  (multipart)       → add option A, get optionId
3. POST  /api/command/practice/question/:questionId/option  (multipart)       → add option B
4. PUT   /api/command/practice/question/:questionId/right-option              → mark option A correct
5. PUT   /api/command/practice/question/:questionId/explanation  (multipart)  → add explanation with optional files
6. POST  /api/command/practice/question/:questionId/fall-number               → tag with subject/fall number
```

### Check how a user is performing

```
GET /api/command/practice/user/stats?email=rahul@example.com
```

### See which questions students are getting wrong the most

```
1. GET /api/command/practice/question              → list all questions
2. GET /api/command/practice/question/:id/stats    → check correct / wrong count per question
```

### Filter questions for a specific course

```
GET /api/command/practice/question?courseId=2
```

Returns only questions whose fall numbers are mapped to course id 2.

### Filter questions for a specific subject (fall number)

```
GET /api/command/practice/question?fallNumberId=3
```

### Search by question code

```
GET /api/command/practice/question?questionCode=GEO
```

Returns all questions whose `questionCode` contains `GEO` (case-insensitive), e.g. `GEO-001`, `geo-042`.

### Paginate through all questions

```
GET /api/command/practice/question?page=0   → first 10
GET /api/command/practice/question?page=1   → next 10
GET /api/command/practice/question?page=2   → next 10
```

Params can be combined: `?questionCode=SCI&fallNumberId=3&page=1`
