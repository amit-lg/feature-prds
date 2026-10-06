# Course Transfer Admin API

Transfer **enrolled users from one course/session into another course**. Built for the admin dashboard flow where an employee picks a source course + session, picks a target course, and moves users across — either all at once or a selected subset.

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

Every request must include the employee token in the header:

```
Authorization: Bearer <employee_token>
```

**Required permission** (checked server-side against the employee's permission tree):

| Action | Permission |
|--------|------------|
| List sessions of a course | `canEditEnrolledUsers` |
| Get enrolled users for a session | `canEditEnrolledUsers` |
| Transfer users between courses | `canEditEnrolledUsers` |

If the employee does not have the permission, the server responds with `403 Forbidden`.

---

## Base URL

```
{{baseUrl}}/api/command
```

---

## UI Flow

```
1. Employee selects a course
        │
        ▼
2. GET /course/:courseId/sessions        ← lists leaf sessions + enrolled counts + flags
        │
        ▼
3. Employee picks the SOURCE session
   └─ Call GET /course/:courseId/session/:sessionId/users for user details / transfer preview
        │
        ▼
4. Employee picks the TARGET session (only ones with isEnrollable === true)
        │
        ▼
5. Employee picks transferMode: "all" / "passed" / "selected"
   └─ "selected" → renders per-user checkboxes from session users endpoint
        │
        ▼
6. POST /transfer-course-users
        │
        ├─ target not enrollable        → 400, show error
        ├─ target has no expiry         → 400 "provide a custom expiry"
        │      └─ prompt user for a date, resend with `customExpiry`
        └─ success                      → show transferred / skipped counts
```

---

## Course structure (how courses, sessions & pathways nest)

Courses form a tree via a self-referencing parent (`courseId`). Every node has a `type`:

| `type` | What it is |
|--------|------------|
| `course` | A grouping/program or a directly-enrollable course (e.g. `CFA`, `Level 1`, `Advance Excel`). |
| `pathway` | An intermediate branch inside a course (e.g. CFA Level 3 → `Portfolio Management`). |
| `session` | A dated offering (e.g. a `2025` year, or a `May` / `Aug` month under it). |

The **leaf** of any branch — the deepest node with no children — is the **actual enrollable unit** a user holds. That leaf is usually a month `session`, but for courses without sessions it can be a leaf `course` (e.g. `Advance Excel`). The tree can be several levels deep:

```
Chartered Financial Analyst (1, course)
├── Level 1 (2, course)
│   ├── 2025 (5, session)
│   │   ├── May (10, session)   ← leaf, enrollable
│   │   ├── Aug (9,  session)   ← leaf, enrollable
│   │   └── Nov (8,  session)   ← leaf, enrollable
│   └── 2026 (92, session)
│       └── May (100, session)  ← leaf, enrollable
└── Level 3 (4, course)
    └── Pathways (56, course)
        └── Portfolio Management (26, pathway)
            └── 2025 (29, session)
                └── Feb (32, session)  ← leaf, enrollable (6 levels deep)
```

`GET /course/:courseId/sessions` returns the **leaf sessions of whatever node you pass**, no matter how deep — so you can pass a `Level 1` id, a `pathway` id, or even the top `CFA` id and get back the enrollable leaves underneath. If the node you pass is itself a leaf, it is returned as the single session.

> A typical transfer moves users from one month session to the next (e.g. `May 2025` → `Aug 2025`) when a new batch opens.

---

## 1. List sessions of a course

Returns the **leaf sessions** under the given course (at any depth — see [Course structure](#course-structure-how-courses-sessions--pathways-nest)). Each session carries only the **enrolled user count** (`enrolledUsers`). To get user details, use endpoint §2.

Use it to let the employee pick the source session, disable non-enrollable target sessions, and preview total enrolment.

```
GET /course/:courseId/sessions
```

**Path params**

| Param | Type | Description |
|-------|------|-------------|
| `courseId` | number | Any course/session/pathway node the employee selected. |

**Response — `200 OK`**

```json
{
  "courseId": 2,
  "sessions": [
    {
      "id": 10,
      "name": "May",
      "abbr": "May",
      "type": "session",
      "expiry": "2025-05-31T01:00:00.000Z",
      "enrolledUsers": 214,
      "isEnrollable": false
    },
    {
      "id": 100,
      "name": "May",
      "abbr": "May",
      "type": "session",
      "expiry": "2026-05-31T01:00:00.000Z",
      "enrolledUsers": 0,
      "isEnrollable": true
    }
  ]
}
```

**Session-level fields**

| Field | Type | Notes |
|-------|------|-------|
| `id` | number | Session (course) id — pass this as `sourceCourseId` or `targetCourseId`, and as `:sessionId` in §2. |
| `name` | string | Display name (e.g. `May`). Often needs the parent path for context — see note below. |
| `abbr` | string \| null | Short code. |
| `type` | string | `course` \| `session` \| `pathway`. |
| `expiry` | ISO string \| null | The session's own expiry. **If `null`, a transfer *into* this session needs a `customExpiry`** (see §3). |
| `enrolledUsers` | number | Total enrolled count. Use for "Transfer N users" preview. |
| `isEnrollable` | boolean | Whether this session can be a transfer target. Show non-enrollable sessions disabled; a transfer into one is rejected with `400` (§3). |

> **Naming tip:** leaf names are short and repeat (every year has a `May`), so they're only unique by id. Disambiguate in the UI using the year session the employee navigated through, or by `expiry`.

**Errors**

| Status | When |
|--------|------|
| `403 Forbidden` | Missing `canEditEnrolledUsers`. |
| `404 Not Found` | `courseId` does not exist. |

---

## 2. Get enrolled user details for a session

Returns all users enrolled in a specific session (leaf course) with their completion status. Use this to populate the per-user selection list when `transferMode: "selected"` is chosen.

```
GET /course/:courseId/session/:sessionId/users
```

**Path params**

| Param | Type | Description |
|-------|------|-------------|
| `courseId` | number | The parent course id (used for routing context). |
| `sessionId` | number | The `id` of the leaf session returned by §1. |

**Response — `200 OK`**

```json
{
  "sessionId": 10,
  "enrolledUsers": 214,
  "students": [
    {
      "userToCourse": {
        "id": 101,
        "userId": 5,
        "expiry": "2025-05-31T01:00:00.000Z",
        "createdAt": "2025-01-10T00:00:00.000Z"
      },
      "user": {
        "id": 5,
        "fname": "Rahul",
        "lname": "Sharma",
        "email": "rahul@example.com",
        "phone": "9876543210"
      },
      "isCompleted": true
    },
    {
      "userToCourse": {
        "id": 102,
        "userId": 8,
        "expiry": "2025-05-31T01:00:00.000Z",
        "createdAt": "2025-02-01T00:00:00.000Z"
      },
      "user": {
        "id": 8,
        "fname": "Priya",
        "lname": "Singh",
        "email": "priya@example.com",
        "phone": "9123456780"
      },
      "isCompleted": false
    }
  ]
}
```

**`students[]` entry fields**

| Field | Type | Notes |
|-------|------|-------|
| `userToCourse.id` | number | Enrollment record id. |
| `userToCourse.userId` | number | User id — use this as the checkbox value and pass in `userIds` when `transferMode` is `"selected"` (see §3). |
| `userToCourse.expiry` | ISO string \| null | Expiry on this specific enrollment. |
| `userToCourse.createdAt` | ISO string | When the user was enrolled. |
| `user.id` | number | User id. |
| `user.fname` | string \| null | First name. |
| `user.lname` | string \| null | Last name. |
| `user.email` | string \| null | Email address. |
| `user.phone` | string \| null | Phone number. |
| `isCompleted` | boolean \| null | Whether the student has completed the course (`CourseUserMeta.isCompleted`). `null` means no meta record exists yet. |

**Errors**

| Status | When |
|--------|------|
| `403 Forbidden` | Missing `canEditEnrolledUsers`. |
| `404 Not Found` | `sessionId` does not exist. |

---

## 3. Transfer users between courses

Moves users enrolled in the source course into the target course. Use `transferMode` to control who gets moved.

```
POST /transfer-course-users
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sourceCourseId` | number | ✅ | Course/session whose enrolled users will be transferred. |
| `targetCourseId` | number | ✅ | Course/session to transfer into. **Must be enrollable** (see rules below). |
| `action` | string | ❌ | `"transfer"` (default) or `"enroll"` — see table below. |
| `transferMode` | string | ❌ | `"all"` (default), `"passed"`, or `"selected"` — see table below. |
| `userIds` | number[] | conditional | **Required when `transferMode` is `"selected"`.** Use `userToCourse.userId` values from the §2 response. |
| `customExpiry` | ISO date string | conditional | **Required only when the target course has no expiry of its own.** |
| `reason` | string | ❌ | Stored on each user's course history. Defaults to an auto-generated note. |

**`action` values**

| Value | Behaviour |
|-------|-----------|
| `"transfer"` | **Moves** the existing enrollment record — the `userToCourse` row is updated to point to `targetCourseId`. The user loses access to the source course. *(Default)* |
| `"enroll"` | **Creates** a new enrollment in the target course — a fresh `userToCourse` row is inserted. The original source enrollment is left intact, so the user retains access to both. |

**`transferMode` values**

| Value | Who is transferred |
|-------|--------------------|
| `"all"` | Every user currently enrolled in the source course (default when omitted). |
| `"passed"` | Only users whose `CourseUserMeta.isCompleted` is `true` for the source course. |
| `"selected"` | Only the user IDs listed in `userIds`. |

**Transfer all users (move enrollment, user loses source)**

```json
{
  "sourceCourseId": 10,
  "targetCourseId": 100,
  "action": "transfer",
  "transferMode": "all",
  "reason": "Batch rollover from May 2025 to May 2026"
}
```

**Enroll all users into a new course (keep source enrollment intact)**

```json
{
  "sourceCourseId": 10,
  "targetCourseId": 100,
  "action": "enroll",
  "transferMode": "all",
  "reason": "Cross-enroll May 2025 batch into May 2026"
}
```

**Transfer only passed students**

```json
{
  "sourceCourseId": 10,
  "targetCourseId": 100,
  "action": "transfer",
  "transferMode": "passed",
  "reason": "Moving graduates to next batch"
}
```

**Enroll individually selected students into a new course**

```json
{
  "sourceCourseId": 10,
  "targetCourseId": 100,
  "action": "enroll",
  "transferMode": "selected",
  "userIds": [5, 8, 23],
  "customExpiry": "2026-12-31T23:59:59.000Z",
  "reason": "Manual partial enroll"
}
```

### Rules the server enforces

1. **Target must be enrollable.** The target course must have the `isEnrollable` course option. If not → `400`.
2. **Source ≠ Target.** Same id for both → `400`.
3. **Expiry resolution:**
   - If the target course has its own expiry (an `expiry` date **or** an `Expiry` days-option), the transfer proceeds; `customExpiry` is optional.
   - If the target has **no** expiry of any kind **and** you did **not** send `customExpiry` → `400` with the message below. This is your cue to prompt the user for a date and resend.
4. **Already-enrolled users are skipped**, not errored. If a user from the source is already enrolled in the target, they're left as-is and counted under `skippedCount`.

**Response — `200 OK` (success)**

```json
{
  "message": "Users transferred successfully",
  "sourceCourseId": 340,
  "targetCourseId": 341,
  "expiry": "2025-12-31T23:59:59.000Z",
  "transferredCount": 212,
  "skippedCount": 2,
  "transferredUserIds": [101, 102, 103]
}
```

| Field | Type | Notes |
|-------|------|-------|
| `expiry` | ISO string \| null | The effective expiry applied (custom expiry, else the target's own expiry). |
| `transferredCount` | number | Users actually moved. |
| `skippedCount` | number | Users skipped because they were already in the target. |
| `transferredUserIds` | number[] | Ids of the moved users. |

**Response — `200 OK` (nothing to do)**

Returned when the candidate set resolves to zero users. The `message` describes why:

| `transferMode` | Message |
|----------------|---------|
| `"all"` | `"No users enrolled in the source course"` |
| `"passed"` | `"No users have completed the source course (isCompleted is not true for any enrolled user)"` |
| `"selected"` | `"None of the selected users are enrolled in the source course"` |

```json
{
  "message": "No users have completed the source course (isCompleted is not true for any enrolled user)",
  "sourceCourseId": 340,
  "targetCourseId": 341,
  "transferredCount": 0,
  "skippedCount": 0
}
```

### Errors

| Status | Message | When |
|--------|---------|------|
| `403 Forbidden` | — | Missing `canEditEnrolledUsers`. |
| `400 Bad Request` | `Source and target courses cannot be the same` | `sourceCourseId === targetCourseId`. |
| `400 Bad Request` | `Target course is not enrollable (missing isEnrollable option)` | Target lacks the `isEnrollable` option. |
| `400 Bad Request` | `Target course has no expiry. Please provide a custom expiry (customExpiry).` | Target has no expiry and `customExpiry` was omitted → **prompt the user for an expiry date and resend.** |
| `404 Not Found` | `Source course not found` | `sourceCourseId` does not exist. |

---

## Frontend notes

- **Restrict the target picker:** only sessions with `isEnrollable === true` (§1) can be transfer targets — show the rest disabled. The server enforces this too (`400`), but filtering up front avoids a failed round-trip.
- **Deciding whether to ask for a custom expiry up front:** the session list (§1) returns each session's `expiry`. If the chosen **target** session has `expiry: null`, show the custom-expiry date picker before submitting. You can also rely on the `400` error as a fallback, but using the `expiry` field gives a smoother UX.
- **Navigating the tree:** `GET /course/:id/sessions` returns leaves at any depth, so you can call it once with a top-level course (e.g. `CFA Level 1`) to get every enrollable session, or drill down node-by-node — whichever fits the UI. See [Course structure](#course-structure-how-courses-sessions--pathways-nest).
- **Loading user details lazily:** the sessions list (§1) only returns counts. Call §2 once the employee selects a source session — this keeps the sessions list lightweight and only loads user details when actually needed.
- **`customExpiry` format:** any value parseable by JS `new Date(...)` (an ISO string is safest).
- **Override behavior:** if you send `customExpiry` while the target *already* has its own expiry, the custom value is written onto the enrollments (it takes precedence). Only send it when you mean to set/override the expiry.
- **Idempotency:** re-running the same transfer is safe — already-moved users land in `skippedCount`, not re-processed.
- **Counts preview:** use `enrolledUsers` from §1 or §2 to show "This will transfer N users" before the employee confirms.
- **Choosing `transferMode`:** surface it as a radio/select in the UI — "Transfer all", "Transfer passed only", "Select individually". Only show the checkbox list when "Select individually" is chosen.
- **Per-user checkboxes (`transferMode: "selected"`):** use `user.fname`/`lname`/`email` for display labels, `isCompleted` to show a "Passed" badge, and `userToCourse.userId` as the checkbox value. Collect the checked ids and send them in `userIds`.
- **`isCompleted` display:** `true` = passed; `false` = enrolled but not yet completed; `null` = no progress record. Consider pre-ticking passed students when in `"selected"` mode so the admin can quickly choose graduates.

---

## Quick Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/command/course/:courseId/sessions` | List leaf sessions with enrolled count |
| GET | `/api/command/course/:courseId/session/:sessionId/users` | Get all enrolled user details for a session |
| POST | `/api/command/transfer-course-users` | Transfer enrolled users between sessions |

---

*Growth Command · Command Module · Course Transfer*
