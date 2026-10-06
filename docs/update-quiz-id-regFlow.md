# Quiz Registrations — Admin Listing & Sorting

Endpoint used by the admin/dashboard to list users registered for a quiz, along
with each user's attempt marks and cheating incidents.

```
GET /api/command/quiz/:quizId/registrations
```

- **Auth:** `EmployeeAuthGuard` — send `Authorization: Bearer <employee-jwt>`.
- **Permission:** requires the `canViewQuiz` employee permission.
- **Service:** `QuizService.adminGetQuizRegistrations` (`src/quiz/quiz.service.ts`).

## Query parameters

All parameters are optional and passed as query string values.

| Param              | Type              | Description                                                                 |
| ------------------ | ----------------- | --------------------------------------------------------------------------- |
| `search`           | string            | Case-insensitive match on user `fname`, `lname`, `email`, or `phone`.       |
| `groupId`          | int               | Filter to a single quiz group.                                              |
| `onlyCheating`     | boolean (`true`)  | Return only users with at least one cheating incident.                      |
| `page`             | int (default `0`) | 0-indexed page. Page size is fixed at **20**.                               |
| `score`            | `asc` \| `desc`   | Sort by the user's **latest attempt** score.                                |
| `registrationTime` | `asc` \| `desc`   | Sort by the user's registration time (`QuizToUser.createdAt`).              |
| `cheating`         | `asc` \| `desc`   | Sort by the user's **total cheating incident count**.                       |

### Sorting behaviour

Only one sort is applied at a time. If more than one sort param is sent, the
precedence is **`score` → `cheating` → `registrationTime`**. If no sort param is
sent, results default to `registrationTime` **descending** (newest first).

1. **`registrationTime`** — sorts on `QuizToUser.createdAt` (`asc`/`desc`).
2. **`cheating`** — for each user, counts *all* of their cheating records across
   all attempts for this quiz, then sorts by that total.
3. **`score`** — for each user, takes their **latest** attempt (most recent
   `createdAt`) and uses its computed marks as the score, then sorts by it.
   Users who have not attempted the quiz (`latestScore = null`) are treated as
   the lowest score.

> Note: `score` and `cheating` are derived from attempt data that has no direct
> DB relation to the registration table, so the API computes them across the
> full matching set before paginating. `total` reflects the full filtered count
> regardless of which sort is active, so pagination is consistent.

## Response shape

```jsonc
{
  "quizId": 10,
  "page": 0,
  "pageSize": 20,
  "total": 42,            // total registrations matching the filters (all pages)
  "maxMarks": 100,        // sum of all question scores for the quiz
  "registrations": [
    {
      "quizId": 10,
      "userId": 5,
      "fieldJson": { /* registration form fields */ },
      "groupId": 3,
      "groupName": "Batch A",
      "registeredAt": "2026-07-01T10:00:00.000Z",
      "updatedAt": "2026-07-01T10:00:00.000Z",
      "user": {
        "id": 5,
        "fname": "Asha",
        "lname": "R",
        "email": "asha@example.com",
        "phone": "9999999999"
      },
      "attempts": [
        {
          "attemptId": 88,
          "hasSubmitted": true,
          "timeTaken": 1200,
          "marks": 80,
          "maxMarks": 100,
          "correctCount": 16,
          "wrongCount": 3,
          "ungradedCount": 1,
          "cheating": [
            { "id": 1, "questionId": 7, "offense": "tab-switch", "createdAt": "…" }
          ],
          "createdAt": "2026-07-02T09:00:00.000Z",
          "updatedAt": "2026-07-02T09:20:00.000Z"
        }
      ],
      "hasAttempted": true,
      "hasCheated": true,
      "latestScore": 80,   // marks of the most recent attempt, or null if none
      "cheatingCount": 1   // total cheating records across all attempts
    }
  ]
}
```

### Fields useful to the frontend

- **`latestScore`** — the value the `score` sort uses; render this as the user's
  current score. `null` means the user has registered but never attempted.
- **`cheatingCount`** — the value the `cheating` sort uses; render as a badge.
- **`hasAttempted` / `hasCheated`** — convenience booleans for list rendering.
- **`attempts[]`** — full per-attempt breakdown (ordered oldest → newest, so the
  last element is the latest attempt). `marks` is the sum of the question scores
  the user answered correctly; `maxMarks` is the quiz total.

## Example requests

```
GET /api/command/quiz/10/registrations?score=desc&page=0
GET /api/command/quiz/10/registrations?cheating=desc
GET /api/command/quiz/10/registrations?registrationTime=asc
GET /api/command/quiz/10/registrations?onlyCheating=true&search=asha
```
