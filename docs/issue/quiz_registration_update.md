# Issue

## Title

Add score / registrationTime / cheating sorting to admin quiz registrations endpoint

## Labels

`backend`, `quiz`, `enhancement`

## Description

The admin quiz registrations endpoint should support sorting the registered
users list by three criteria. The `AdminGetQuizRegistrationsDto` already exposed
`score`, `registrationTime`, and `cheating` (each `asc` | `desc`), but
`adminGetQuizRegistrations` did not implement them correctly — the sort
directions were being written into Prisma `where` filters (including a
non-existent `total` field on cheating records) and were never applied to
`orderBy`, so the list always came back ordered by `createdAt desc`.

**Endpoint:** `GET /api/command/quiz/:quizId/registrations`
**Service:** `QuizService.adminGetQuizRegistrations` (`src/quiz/quiz.service.ts`)

### Requirements

1. **registrationTime** (`asc`/`desc`) — sort by `QuizToUser.createdAt`.
2. **cheating** (`asc`/`desc`) — sort by the total number of cheating records
   per user, counted across all of their attempts for the quiz.
3. **score** (`asc`/`desc`) — sort by the score of the user's latest attempt
   (most recent `createdAt`).

### Notes / constraints

- `score` and `cheating` are derived from `UserQuizAttempt` /
  `QuizUserCheating`, which have no direct relation to `QuizToUser`, so they
  cannot be expressed in a Prisma `orderBy` on the registration table. These
  sorts must load the full filtered set, compute the metric per user, sort, then
  paginate in memory. `registrationTime` (and the default) can stay
  DB-paginated.
- Only one sort applies at a time; precedence when multiple are sent:
  `score → cheating → registrationTime`. Default remains `registrationTime desc`.
- Users with no attempt should sort as the lowest score (`latestScore = null`).
- `total` must remain the full filtered count so pagination stays consistent
  across sorts.

### Acceptance criteria

- [ ] Passing `score=asc|desc` orders users by their latest attempt marks.
- [ ] Passing `cheating=asc|desc` orders users by total cheating count.
- [ ] Passing `registrationTime=asc|desc` orders by registration time at the DB level.
- [ ] No sort param → defaults to `registrationTime desc` with DB pagination.
- [ ] `onlyCheating` / `search` / `groupId` filters still work alongside sorting.
- [ ] Response includes `latestScore` and `cheatingCount` per registration.
- [ ] Unit tests cover each sort direction and the default.

## Status

Implemented on branch `canary`. Endpoint, DTO, docs, and unit tests updated
(`src/quiz/quiz.service.ts`, `docs/update-quiz-id-regFlow.md`,
`src/quiz/quiz.service.spec.ts`).
  