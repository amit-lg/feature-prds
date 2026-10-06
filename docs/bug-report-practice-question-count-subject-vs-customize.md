# Bug Report: Practice question count is higher via Subject than via Customize Question Count

**Repo:** GrowthCommand (this repo)
**Module:** Practice (`src/practice/`)
**Reported by:** Durgesh Tiwari
**Date:** 2026-07-10
**Status:** Open — root cause confirmed against live data

## Summary

For the same subject, browsing question count via "Subject" shows a higher number than the count returned by "Customize Question Count". **The Subject count is the one that's wrong — it double-counts questions.** Root cause, verified directly against the database: `findSubject`'s recursive per-node counting logic adds a question again every time its underlying `FallNumber` is tagged to more than one subject node within the same subtree (e.g. tagged to both a parent chapter and one of its child topics). `getPracticeQuestionDifficulty` (Customize) does a single flat `count()` over distinct `PracticeQuestion` rows, so it's immune to this and returns the correct, deduplicated number.

Note: there is no "customize question count" concept in the Quiz module — this is a **Practice**-module-only feature (`POST /practice/customizequestioncount`), separate from the earlier quiz bugs reported.

## Reproduction data (real, from this environment)

Subject endpoint response for chapter "90. Hedge Fund Investment Strategies" (`id: 18984`, `subjectId: 18936` is its parent):
```json
{ "id": 18984, "name": "90. Hedge Fund Investment Strategies", "subjectId": 18936, "questionCount": 19, "itemset": [] }
```
Customize Question Count response for the same chapter (`subjectIds: [18984]`, `courseId: "334"`, all three difficulty flags true, all three attempt-status flags false):
```json
{ "questionCount": 15, "itemset": [] }
```

I ran read-only diagnostic queries directly against the configured database (with explicit sign-off before connecting to it, since it's not a local dev DB) to find out which of the two numbers is correct:

- Course `334` has a `courseOption` row with `key: 'templateCourseId'` and `valueText: '104'` — so the actual course used for question-matching (by both endpoints, via `getPracticeQuestionDifficulty`'s template-course override at `practice.service.ts:1042-1051`) is course **104**, not 334 itself.
- The subtree rooted at subject `18984` has 4 direct child subjects (`18985`, `18986`, `18987`, `18988`), all one level down, each with directly-attached practice questions via `FallNumber`.
- A **single, distinct-row count** of `PracticeQuestion` across course 104 and this entire subject subtree (18984 + its 4 children) returns **15** — matching Customize exactly.
- Summing question counts **per subject node separately** (4 at node 18984, 4 at node 18985, 1 at node 18986, 7 at node 18987, 3 at node 18988 = 19) reproduces the Subject page's **19** exactly.
- The reason: one `FallNumber` (id `4141`, linked to 4 practice questions) is tagged to **both** `subjectId: 18984` (the root chapter) **and** `subjectId: 18985` (one of its children) in `FallNumberToSubject`. Those 4 questions are legitimately counted once at the root node and then counted *again* when the recursion descends into the child node — inflating 15 real, distinct questions into 19.

This is a precise, data-confirmed mechanism, not a guess: `15 distinct + 4 double-counted duplicates = 19`.

## Where each count comes from

**Subject-based count (has the bug)** — `GET /practice/subject` (`src/practice/practice.controller.ts:178-190`) → `PracticeService.findSubject` (`src/practice/practice.service.ts:3782`) → `newFindQuestionStats` (`src/practice/practice.service.ts:4172-4232`):

```ts
// src/practice/practice.service.ts:4192-4194
for (const fallNumber of subject.FallNumber) {
  for (const practiceQuestion of fallNumber.Fall.PracticeQuestion) {
    totalQuestionCount++;
```
and, recursively, for every child subject:
```ts
// src/practice/practice.service.ts:4215-4222
if (subject.Subjects && subject.Subjects.length > 0) {
  for (const childSubject of subject.Subjects) {
    const childStats = this.newFindQuestionStats(childSubject, parentQuestionMap);
    totalQuestionCount += childStats.totalQuestionCount;
```

`subject.FallNumber` at each recursion level is populated from `CourseSubject.FallNumber` (i.e. `FallNumberToSubject` rows whose `subjectId` equals *that specific node's id*, `practice.service.ts:3915-3926`). `FallNumberToSubject` (`prisma/schema.prisma:695-701`) is a plain many-to-many join — a single `FallNumber` can legitimately have more than one row in it, tagging the same underlying questions to more than one `CourseSubject` node (e.g. a chapter-level overview `FallNumber` also tagged to one of its own sub-topics). Because the function sums per-node counts with `totalQuestionCount += childStats.totalQuestionCount` and never tracks which `FallNumber`/question IDs have already been counted across the whole recursion, any such shared tagging is counted once per node it appears under.

**Customize Question Count (correct)** — `POST /practice/customizequestioncount` (`src/practice/practice.controller.ts:164-176`) → `PracticeService.getPracticeQuestionDifficulty` (`src/practice/practice.service.ts:1030-1509`):

```ts
// src/practice/practice.service.ts:1053-1060 (abbreviated)
const practiceQuestionCount = await this.databaseService.practiceQuestion.count({
  where: {
    questionId: null,
    Formula: { none: {} },
    FallNumber: { some: { FallNumber: { Course: {...}, Subject: { some: { Subject: { OR: [...subjectIds match, walking up to 4 ancestor levels...] } } } } } },
    AND: [ /* isFlagged/isIncorrect/isUnattempted */, /* includeEasy/Medium/Hard */ ],
  },
});
```

This is a single `count()` over the `PracticeQuestion` table with a `where` clause — Prisma/SQL naturally returns the number of *distinct* matching rows, so a question matching the subject filter via more than one tagged `FallNumber`/subject relation still only counts once. This is why 15 is correct and 19 is not.

(For this specific data point, `questionId: null` and the difficulty filters made no difference — all 15 matching rows have non-null difficulty and none are item-set children — so the discrepancy here is purely the double-counting bug above, not the item-set/difficulty-filtering behavior noted below.)

## Secondary bug, same code path, confirmed by reading (not yet hit by this specific data point)

`getPracticeQuestionDifficulty`'s headline `practiceQuestionCount` filters `questionId: null` (`practice.service.ts:1056`), excluding item-set/passage sub-questions from the number, while `findSubject` has no such filter and would include them. The `itemSetCount` query meant to report those separately (`practice.service.ts:1195-1501` → `itemset` array) only matches container/parent rows that themselves have a `FallNumber` link — but per `addPractice` (`practice.service.ts:3413-3507`), only the **child** rows of an item set get a `FallNumber` link, never the parent container. So `itemset` will likely always come back empty even when item-set children exist and are being excluded from `questionCount` — this wasn't the cause of the 19-vs-15 gap in the reproduced case (no item sets were involved here), but it's a latent bug worth fixing in the same pass: for any subject that *does* contain item-set questions, Customize's `questionCount` would under-count relative to Subject's, and the `itemset` array wouldn't surface them to compensate.

Also present but not the cause here: unchecked `includeEasy`/`includeMedium`/`includeHard` and `isFlagged`/`isIncorrect`/`isUnattempted` flags are spread into empty `{}` objects inside their `OR` arrays (`practice.service.ts:1113-1192`, mirrored in the `itemSetCount` query), which makes the whole `OR` unconditionally true whenever not all three flags in a group are set — silently disabling that filter instead of narrowing it. Verified in this data point to have no effect (all three difficulty flags were true, and no `nullDifficulty` rows exist in this subtree), but it's a correctness bug that should be fixed in the same pass.

## Suggested fix

**Primary (fixes the reported bug):** `newFindQuestionStats` (`practice.service.ts:4172-4232`) needs to deduplicate across the whole recursive walk, not just within a single node. Pass a `Set` of already-counted `PracticeQuestion` ids (or `FallNumber` ids) through the recursion and skip any row already seen:

```ts
newFindQuestionStats(subject, parentQuestionMap, seenQuestionIds = new Set<number>()) {
  ...
  for (const fallNumber of subject.FallNumber) {
    for (const practiceQuestion of fallNumber.Fall.PracticeQuestion) {
      if (seenQuestionIds.has(practiceQuestion.Question.id)) continue;
      seenQuestionIds.add(practiceQuestion.Question.id);
      totalQuestionCount++;
      ...
```
and thread `seenQuestionIds` into the recursive call for `childSubject`. Alternatively, replace the whole recursive tree-walk with a single `practiceQuestion.count()`/`findMany()` scoped to "this subject or any descendant" (mirroring how `getPracticeQuestionDifficulty` already queries), which sidesteps the double-counting class of bug entirely rather than patching around it.

**Secondary:** fix the `itemset`/`questionId: null` exclusion (fold item-set child counts back into `questionCount`, or fix `itemSetCount`'s query to actually find item-set parents given only children carry `FallNumber` links) and fix the `OR`-array-of-`{}` issue by building filter arrays conditionally instead of spreading falsy flags into empty objects:
```ts
OR: [
  ...(includeEasy ? [{ difficulty: { lte: 3 } }] : []),
  ...(includeMedium ? [{ difficulty: { gte: 4, lte: 7 } }] : []),
  ...(includeHard ? [{ difficulty: { gte: 8 } }] : []),
]
```

## Suggested validation steps

1. Re-run `GET /practice/subject` for subject `18984` (course 334 / effective course 104) after the fix and confirm `questionCount` becomes 15, matching Customize.
2. Find another subject with genuinely nested (3+ level) subject trees and confirm counts still reconcile — this bug scales with how many subject nodes a single `FallNumber` is tagged to and how deep the tree is.
3. Separately, test against a subject known to contain item-set/passage questions to validate the secondary fix (Customize's `questionCount` should then include item-set children, or clearly report them via a working `itemset` array).
