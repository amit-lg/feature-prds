# Bug Report: Quiz shows ~100 questions but only 4-6 appear in the actual test

**Repo:** GrowthCommand (this repo)
**Reported by:** Durgesh Tiwari
**Date:** 2026-07-10
**Status:** Open

## Summary

Students see a quiz listed with a large question count (e.g. ~100), but when they actually start the quiz attempt, only a handful of questions (4-6 in reported cases) show up in the test.

Root cause: the code path that **counts/displays** questions and the code path that **selects questions for an actual attempt** are inconsistent. The display path counts all linked questions with no filtering. The attempt path runs every question through `segregateQuestions`, which silently drops any question whose `canShuffle` field is not exactly `null` — and any question an admin has explicitly toggled shuffle on/off for (via the normal question edit flow) ends up with a non-null `canShuffle`, making it invisible to real attempts while still being counted in the listing.

## Where the displayed count comes from

Two places compute the "shown" question count, neither of which filters on `canShuffle`:

- **Student listing** — `QuizController.getQuiz` (`src/quiz/quiz.controller.ts:31-38`) → `QuizService.findAll` (`src/quiz/quiz.service.ts:1601`). The `Questions` include is filtered only by a FallNumber/Course match (`src/quiz/quiz.service.ts:1904-1966`). The displayed count is then a plain iteration over every returned question and its children, with no exclusion:
  ```
  src/quiz/quiz.service.ts:2077-2136
  for (const quiz of quizes) {
    let questionCount = 0;
    for (const question of quiz.Questions) {
      const hasChildren = question.Questions && question.Questions.length > 0;
      if (hasChildren) {
        for (const childQuestion of question.Questions) {
          questionCount += 1;
          ...
  ```
- **Admin listing** — `adminGetQuiz` (`src/quiz/quiz.service.ts:5641-5665`) is even more direct — a raw row count with no filtering at all:
  ```
  src/quiz/quiz.service.ts:5643-5645
  const questionCount = await this.databaseService.quizQuestion.count({
    where: { quizId: id },
  });
  ```

## Where the actual test questions come from

Real-time flow: `make-quiz-attempt` socket event (`src/user/user.gateway.ts:388-417`) → `QuizService.startQuiz` (`src/quiz/quiz.service.ts:2333`). The subsequent `give-quiz-questions` event (`user.gateway.ts:419-439`) → `getQuizQuestions` (`quiz.service.ts:3151`) just reads back whatever `startQuiz` already created — no further filtering there.

Inside `startQuiz`, the question set for the attempt is built at `src/quiz/quiz.service.ts:2796-2811`:

```ts
if (questions?.length === 0) {
  const { questionsCanBeShuffled, questionsCannotBeShuffled } =
    this.segregateQuestions(quizone.Questions);

  const shuffledQuestions = await this.shuffleArray(
    questionsCanBeShuffled,
    String(isEnrolled?.groupId),
  );

  const index = shuffledQuestions.length + 1;
  shuffledQuestions.splice(index, 0, ...questionsCannotBeShuffled);
  questions = this.getQuestionForUserAnswer(shuffledQuestions);
```

`segregateQuestions` (`src/quiz/quiz.service.ts:3001-3014`) is the actual filter, and it's the root cause:

```ts
segregateQuestions(questions = []) {
  const questionsCanBeShuffled = [];
  const questionsCannotBeShuffled = [];

  for (const q of questions) {
    if (q?.canShuffle === null && q?.questionId === null) {
      questionsCanBeShuffled.push(q);
    } else if (q?.canShuffle === false && q?.quizId === null) {
      questionsCannotBeShuffled.push(q);
    }
  }

  return { questionsCanBeShuffled, questionsCannotBeShuffled };
}
```

This has only two branches and no `else` — any question that matches neither condition is silently dropped (added to neither array), and `questions.length` after this becomes the actual number of questions the student sees in the test.

## Why this drops most questions

- `canShuffle` is a nullable boolean on `QuizQuestion` (`prisma/schema.prisma:816` — `canShuffle Boolean?`), with no DB default, so it stays `NULL` until explicitly set.
- A question only survives into `questionsCanBeShuffled` if `canShuffle === null` (and it's a top-level question, `questionId === null`).
- The second branch (`canShuffle === false && quizId === null`) is effectively dead for top-level questions: every question reached via the `Quiz.Questions` relation necessarily has `quizId` equal to the quiz's own id (that's how the relation resolves it), so `quizId === null` can basically never be true here. This branch essentially never fires.
- Net effect: a question is only ever included in a real attempt if its `canShuffle` column is still `NULL`. Any question where an admin has touched the shuffle toggle — setting it to either `true` or `false` via the question edit flow — becomes permanently excluded from attempts, while remaining fully counted in both the student and admin listings (which don't look at `canShuffle` at all).

This matches the reported symptom: a quiz with ~100 questions where only a handful still have `canShuffle = NULL` (e.g. older/untouched questions) would show ~100 in the listing but only produce those 4-6 `NULL`-shuffle questions in an actual attempt.

## Secondary/compounding factor

`startQuiz`'s `Questions` include (`src/quiz/quiz.service.ts:2421-2605`) applies an extra subject-enrollment filter (`Subject: { every: {...} }` against `enrolledSubjectIds`, populated at `src/quiz/quiz.service.ts:2363-2378`) that the listing query in `findAll` does not have. If a student's `enrolledSubjectIds` doesn't cover all subjects linked to the quiz's questions, those questions are excluded from `quizone.Questions` before `segregateQuestions` even runs — further shrinking the pool for that student specifically, and explaining why the shortfall could vary between students. This alone wouldn't produce a consistent "4-6 out of 100" for everyone, but it can compound the primary bug above.

## Suggested fix

In `segregateQuestions` (`src/quiz/quiz.service.ts:3001-3014`), add a fallback branch so questions with a non-null `canShuffle` are still included (e.g. treat any question with `canShuffle === true` or `canShuffle === false` as "cannot be shuffled" regardless of `quizId`, since the current `quizId === null` condition on that branch appears to be a leftover/incorrect condition):

```ts
for (const q of questions) {
  if (q?.canShuffle === null && q?.questionId === null) {
    questionsCanBeShuffled.push(q);
  } else if (q?.questionId === null) {
    // canShuffle is true or false — still a valid top-level question
    questionsCannotBeShuffled.push(q);
  }
}
```

Also worth reconciling the display-count logic (`findAll` at `quiz.service.ts:2077-2136`, `adminGetQuiz` at `quiz.service.ts:5641-5665`) with whatever the corrected attempt-selection logic ends up being, so the number shown to students/admins always matches what an attempt will actually contain — otherwise a similar mismatch could resurface under a different filtering condition in the future.

## Suggested validation steps

1. Query the DB for a known-affected quiz: `SELECT id, canShuffle FROM "QuizQuestion" WHERE "quizId" = <id> AND "questionId" IS NULL;` — confirm most rows have non-null `canShuffle` while only ~4-6 have `NULL`.
2. Apply the fix, re-run `startQuiz` for that quiz, and confirm the created `UserQuizAnswer` row count now matches the listed question count.
3. Check whether any existing quizzes/attempts need a data backfill (e.g. did anyone already take these truncated quizzes and get scored on artificially few questions?).
