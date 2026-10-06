# Practice Student Dashboard API

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

```
Authorization: Bearer <employee_token>
```

**Required permission:** `canViewPractice`

---

## Base URL

```
/api/command
```

---

## Overview

Three endpoints that give a full view of how students are performing on practice. They support drilling down through a multi-level course hierarchy and a shared date-range filter.

### Course Hierarchy

Courses are self-referential — every node can have children and each child can have children of its own. The actual depth varies by product. For example:

```
CFA (id=1)
├── Level 1 (id=2)
│   ├── 2025 (id=5)
│   │   ├── Feb (id=7)
│   │   ├── May (id=10)
│   │   ├── Aug (id=9)
│   │   └── Nov (id=8)
│   ├── 2026 (id=92)
│   │   ├── Feb (id=93)
│   │   ├── May (id=100)
│   │   └── Aug (id=163)
│   └── 2027 (id=194)
│       ├── Feb (id=195)
│       ├── May (id=325)
│       └── Aug (id=338)
├── Level 2 (id=3)
├── Level 3 (id=4)
│   ├── Pathways (id=56)
│   │   ├── Portfolio Management (id=26)
│   │   ├── Private Markets (id=27)
│   │   └── Private Wealth (id=28)
│   └── ...
└── Ethics (id=114)

FRM (id=38)
├── Part 1 (id=39)
│   ├── 2025 (id=41)
│   │   ├── May (id=43)
│   │   ├── Aug (id=48)
│   │   └── Nov (id=44)
│   └── 2026 (id=103)
└── Part 2 (id=40)

CA (id=354)
├── Foundation (id=355)
│   ├── 2026 (id=356) → September (id=357)
│   └── 2027 (id=358) → January / May / September
├── Intermediate (id=362)
└── Final (id=369)
```

### How Drill-Down Works

Each call to the summary endpoint returns `childCourses` — the direct children of whichever course is currently in scope. Pass one of those `id` values as `childCourseId` to go one level deeper. Repeat as many times as the tree goes.

**Shared filter params** — accepted by all three endpoints:

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `courseId` | integer | **Yes** | The anchor course for the view |
| `childCourseId` | integer | No | Narrow to this direct or indirect child of `courseId` |
| `startDate` | ISO date string | No | Include attempts on or after this date |
| `endDate` | ISO date string | No | Include attempts on or before this date |

The effective course used for filtering is: `childCourseId` if provided, otherwise `courseId`.

---

## Endpoints

---

### 1. Summary

```
GET /api/command/practice/dashboard
```

Returns aggregate stats across all students for the scoped course, plus the direct children of that course for navigation.

**Query params** — see shared filter table above.

**Response**

```json
{
  "courseId": 2,
  "childCourses": [
    { "id": 57, "name": "2024", "abbr": "2024" },
    { "id": 5,  "name": "2025", "abbr": "2025" },
    { "id": 92, "name": "2026", "abbr": "2026" },
    { "id": 194,"name": "2027", "abbr": "2027" }
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
| `childCourses` | Direct children of the effective course. Pass one of these `id` values as `childCourseId` to drill one level deeper. |
| `totalEnrolled` | Students with an active enrollment (`UserToCourse`) for the effective course. |
| `studentsAttempted` | Distinct students who started at least one practice session. |
| `studentsNeverAttempted` | `totalEnrolled − studentsAttempted` (minimum 0). |
| `totalAttempts` | Total practice sessions created in scope. |
| `totalAnswered` | Individual questions submitted across all sessions. |
| `overallCorrect` | MCQ: selected option was the right option. Essay: grader marked `isCorrect = true`. |
| `overallWrong` | MCQ: non-right option selected. Essay: `isCorrect = false`. |
| `overallUngraded` | Submitted but correctness not yet determined (essay pending grading). |
| `studentsWithFirstTimeCorrect` | Students who got **at least one** question correct on their very first attempt at it. |
| `studentsWithFirstTimeWrong` | Students who got **at least one** question wrong on their very first attempt at it. |

---

### 2. Per-Student Breakdown

```
GET /api/command/practice/dashboard/students
```

Lists students who have attempted practice in the scoped course with per-student stats including first-time-correct and first-time-wrong counts. Returns **20 students per page**, ordered by most-recently-active first.

**Query params**

| Param | Type | Description |
|-------|------|-------------|
| *(shared filters)* | | `courseId`, `childCourseId`, `startDate`, `endDate` |
| `search` | string | Case-insensitive match on first name, last name, email, or phone |
| `page` | integer | 0-indexed page number. Defaults to `0`. |

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
    "lastAttemptAt": "2025-11-01T10:00:00.000Z"
  }
]
```

| Field | Meaning |
|-------|---------|
| `totalAttempts` | Practice sessions started (submitted or not). |
| `totalAnswered` | Questions submitted by this student in the scope. |
| `correct` | Questions answered correctly across all attempts (cumulative). |
| `wrong` | Questions answered incorrectly across all attempts (cumulative). |
| `ungraded` | Submitted but not yet graded (essay pending). |
| `firstTimeCorrect` | Questions this student got right on their **first-ever** attempt at each question. |
| `firstTimeWrong` | Questions this student got wrong on their **first-ever** attempt at each question. |
| `lastAttemptAt` | Timestamp of their most recent practice session. |

---

### 3. Per-Question Breakdown

```
GET /api/command/practice/dashboard/questions
```

Lists root-level questions in the scoped course with the number of unique students who attempted each one and how many got it right vs wrong on their first try. Returns **20 questions per page**, ordered by `priority ASC, id ASC`.

**Query params**

| Param | Type | Description |
|-------|------|-------------|
| *(shared filters)* | | `courseId`, `childCourseId`, `startDate`, `endDate` |
| `fallNumberId` | integer | Limit to questions tagged with this fall number (subject). |
| `page` | integer | 0-indexed page number. Defaults to `0`. |

**Response** — array of question rows

```json
[
  {
    "id": 1,
    "questionCode": "CFA-L1-001",
    "question": "Which of the following best describes...",
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
| `firstTimeCorrect` | Students who answered correctly on their **first-ever** attempt at this question. |
| `firstTimeWrong` | Students who answered incorrectly on their first attempt. |
| `firstTimeUngraded` | Students whose first attempt on this question is still ungraded (essay). |

---

## How "First Time" Is Calculated

For every (student, question) pair, only the answer from the **chronologically earliest practice session** is considered. If a student attempted the same question across multiple sessions, only their first answer counts for `firstTimeCorrect` / `firstTimeWrong`.

- **First-time correct**: MCQ — selected option was the right option. Essay — graded `isCorrect = true`.
- **First-time wrong**: MCQ — selected a non-right option. Essay — graded `isCorrect = false`.
- **First-time ungraded**: Essay submitted but not yet graded by an instructor.

---

## Typical Flows

### Level 1 — all CFA Level 1 students, all time

```
GET /api/command/practice/dashboard?courseId=2
```

Response includes `childCourses: [{id:57,"2024"}, {id:5,"2025"}, {id:92,"2026"}, {id:194,"2027"}]`

### Level 2 — narrow to CFA Level 1 / 2025 batch

```
GET /api/command/practice/dashboard?courseId=2&childCourseId=5
```

Response includes `childCourses: [{id:7,"Feb"}, {id:10,"May"}, {id:9,"Aug"}, {id:8,"Nov"}]`

### Level 3 — narrow to CFA Level 1 / 2025 / Nov sitting

```
GET /api/command/practice/dashboard?courseId=2&childCourseId=8
```

No further children — `childCourses` will be empty.

### FRM Part 1 / 2025 / May — student list

```
GET /api/command/practice/dashboard/students?courseId=39&childCourseId=43&page=0
```

### Search for a student across all of CA Foundation 2027

```
GET /api/command/practice/dashboard/students?courseId=355&childCourseId=358&search=rahul
```

### See hardest questions for CFA Level 1 / Nov 2025

```
GET /api/command/practice/dashboard/questions?courseId=2&childCourseId=8
```

Sort `firstTimeWrong` descending on the frontend to surface questions most students get wrong on first try.

### Date-range filter — activity during a revision window

```
GET /api/command/practice/dashboard/students?courseId=2&childCourseId=8&startDate=2025-10-01&endDate=2025-11-30
```

---

## Error Responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | `courseId` missing or not a valid integer |
| `401 Unauthorized` | Missing or invalid employee token |
| `403 Forbidden` | Employee does not have `canViewPractice` permission |
