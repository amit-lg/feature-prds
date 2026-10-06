# PRD: Subject Compass & Chapter Compass

**Status:** Draft
**Author:** Durgesh Tiwari (via Claude Code)
**Date:** 2026-07-16
**Repo:** GrowthCommand (backend) — student-facing surface consumed by the student portal (`SudentExamClub` / equivalent frontend)

---

## 1. Summary

Today a student's progress is scattered across three unrelated screens, each scoped to a single content type:

- `GET /lecture/subject-progress` — video/lecture completion, rolled up by subject → chapter → LOS.
- `GET /practice/subject-result`, `GET /practice/subject` — practice-question performance, its own subject view.
- `GET /formula/subjects` — formula mastery, its own subject view.

A student cannot answer "how am I doing in **Thermodynamics** overall?" without visiting three different tabs and mentally merging three different progress bars. **Subject Compass** and **Chapter Compass** fix this by giving the student one navigable view of their standing across videos, practice questions, and formulas, organized by the syllabus tree they already know (subject → chapter → LOS/topic).

- **Subject Compass** — a course-level dashboard listing every subject the student's enrolled course covers, each with a blended progress snapshot across all three content types.
- **Chapter Compass** — the drill-down from one subject: its chapters (and any nested topic/LOS level), each with the same three-way breakdown, plus direct links into the actual videos/questions/formulas for that chapter.

This is a rollup feature, not a new content type. No new authoring surface is introduced — it reads content and progress that already exists (`FallNumber`, `CourseSubject`, `UserToVideoInfo`, `UserPracticeAnswer`, `FormulaToUser`) and reshapes it into one tree.

---

## 2. Background — how the data already connects

Three independent content pipelines converge on the same two tables, which is what makes this feature possible without new data modeling:

```
CourseSubject (self-referential tree: subject → chapter → LOS → ...)
      ▲
      │  FallNumberToSubject
      │
  FallNumber  ──FallNumberToVideoInfo──►  VideoInfo   (lectures)
      │       ──PracticeQuestiontoFallNumber──►  PracticeQuestion
      │       ──FormulaToFallNumber──►  Formula
      │       ──QuizQuestiontoFallNumber──►  QuizQuestion   (out of scope, see §9)
      └──FallNumberToCourse──►  Course
```

`FallNumber` is the tag every content item carries; `CourseSubject` is the syllabus tree it's tagged into. `docs/course-models.md` and `docs/formula-admin-api.md` / `docs/practice-admin-api.md` document the admin side of this tagging. `docs/lecture-plan-feature.md` (`GET /lecture/subject-progress`) already implements exactly this rollup pattern for videos alone — Subject/Chapter Compass generalizes that same pattern to all three content types and is the natural reference implementation to extend from.

Per-user progress already exists per content type, with no schema changes needed:

| Content type | Progress source | Signal |
|---|---|---|
| Videos | `UserToVideoInfo` | `done` (true/false/null), `seen` (seconds) |
| Practice questions | `UserPracticeAnswer` (via `UserPracticeAttempt`) | `isCorrect`, joined to `PracticeQuestion` |
| Formulas | `FormulaToUser` | `isRight`, one row per attempt |

---

## 3. Problem statement

- Students preparing for an exam think in terms of subjects and chapters ("I'm weak in Organic Chemistry"), not content types ("I'm weak in videos"). The product currently has no view that matches that mental model.
- There's no single place to spot a chapter that's "watched but never practiced" (video done, zero practice attempts) or "practiced but not understood" (many wrong practice answers despite completed videos) — these are exactly the gaps a student needs surfaced before an exam.
- Related student-portal bug reports (`docs/bug-report-student-portal-course-overview.md`) describe the existing Overview/readiness experience as unreliable (wrong default course, broken course-switch navigation, readiness not rendering). Subject/Chapter Compass is a chance to replace that fragile surface with something built on solid, already-proven rollup logic (the same pattern `/lecture/subject-progress` uses in production), rather than patch the old one.

## 4. Goals

1. Give a student a single screen (**Subject Compass**) showing, per subject in their enrolled course, blended progress across videos, practice questions, and formulas.
2. Give a student a drill-down screen (**Chapter Compass**) for one subject, showing the same blend per chapter (and per LOS/topic, where the syllabus goes that deep), with direct links to jump into that chapter's content.
3. Surface actionable gaps — e.g. a chapter with completed videos but no practice attempts — not just aggregate percentages.
4. Reuse existing tagging/data (`FallNumber`, `CourseSubject`) with no new authoring workflow for content teams.

## 5. Non-goals

- No changes to how content is authored, tagged, or fall-numbered — this is a read-only rollup.
- No new mastery/spaced-repetition algorithm. "Mastery" here means the current pass/fail state per item, not a computed retention score (see §8.3 for the exact definition, and §9 for future scoring ideas).
- Quiz questions and doubt-forum activity are tagged with `FallNumber` too (`QuizQuestiontoFallNumber`, `DoubtQuestion`) but are **out of scope** for v1 — see §9 (Open Questions).
- Not a replacement for the Study Plan (`docs/lecture-plan-feature.md`). Study Plan answers "what should I watch today"; Compass answers "how am I doing overall." They can — and should — cross-link (see §8.6).
- Not fixing the specific bugs in `bug-report-student-portal-course-overview.md` directly (different repo, different screen) — but Compass's course-resolution should not repeat the same mistake (see §8.5).

## 6. Users

- **Student**, mid-course, checking standing before a test or exam — primary user, primary scenario for both screens.
- **Student**, deciding what to study next when the Study Plan feels too rigid — secondary scenario for Chapter Compass ("show me the weak chapter, I'll pick a video myself").
- Not employee/admin-facing. No Command-module changes required for v1 (existing admin CRUD for practice/formula/video/fall-number already covers content management, see `docs/practice-admin-api.md`, `docs/formula-admin-api.md`, `docs/lecture-video-admin-api.md`).

## 7. User stories

1. As a student, I open Subject Compass and see every subject in my course with a progress bar, so I know at a glance which subjects I'm behind on.
2. As a student, I tap a subject and see its chapters (and topics within a chapter), each broken down by video/practice/formula, so I can find exactly where I'm weak.
3. As a student, I see a chapter where I've watched all the videos but attempted 0 practice questions, and the UI calls this out distinctly from "chapter not started," so I know practicing (not watching) is my next step.
4. As a student, I tap into a chapter's practice questions or formulas directly from Chapter Compass, so I don't have to leave the screen and re-navigate through the Practice or Formula tab's own subject picker.
5. As a student with content that has no subject tag (`FallNumber` untagged, or tagged but with no `FallNumberToSubject` link), I still see it counted somewhere ("Unassigned") rather than silently missing from my totals.

## 8. Functional requirements

### 8.1 Subject Compass (course-level)

Course-level screen, one row per **root** `CourseSubject` (`type: "subject"`) tagged to the student's course.

Per subject, show:

| Field | Meaning |
|---|---|
| `name` | Subject name |
| Video stats | `total` / `done` / `inProgress` / `notStarted` |
| Practice stats | `total` / `attempted` / `correct` / `wrong` / `unattempted` |
| Formula stats | `total` / `attempted` / `mastered` / `needsReview` / `unattempted` |
| `overallPercent` | A single blended number for the subject's progress bar (see §8.4 for the formula) |
| `chapterCount` | Number of direct child chapters, so the UI can show "8 chapters" |

Sort order: by the subject's own `CourseSubject.order` (matches existing convention in `/lecture/subject-progress` — no client-side re-sort needed).

An `unassigned` bucket (same shape, minus `name`/`chapterCount`) rolls up any content tagged with a `FallNumber` that has no `FallNumberToSubject` link at all — mirrors the existing `unassigned` block in `/lecture/subject-progress`.

### 8.2 Chapter Compass (subject drill-down)

Given a `subjectId` (a root subject from Subject Compass), return that subject's full descendant tree — chapters, and any nested LOS/topic level below that — with the same three-way stats per node, recursively summed (a chapter's totals = its own directly-tagged content + everything nested beneath it, same rollup rule as `/lecture/subject-progress`).

Each **leaf-adjacent** node (a chapter or topic with directly-tagged content, not just a pass-through folder) additionally exposes enough to jump straight into content:

```json
{
  "id": 12,
  "name": "Thermodynamics",
  "type": "chapter",
  "order": 2,
  "otherJson": { "difficulty": "Hard", "confusing": "Yes", "implevel": "High" },
  "video":    { "total": 10, "done": 5, "inProgress": 1, "notStarted": 4 },
  "practice": { "total": 40, "attempted": 30, "correct": 18, "wrong": 12, "unattempted": 10 },
  "formula":  { "total": 6,  "attempted": 4,  "mastered": 3, "needsReview": 1, "unattempted": 2 },
  "overallPercent": 55,
  "children": [ ... ],
  "links": {
    "videos": "/lecture/lectures?fallId=7",
    "practice": "/practice/subject?subjectId=12",
    "formulas": "/formula/subjects?subjectId=12"
  }
}
```

`otherJson` (already populated on `CourseSubject` for chapters imported via `POST /lecture/chapter/extra` — see `docs/lecture-plan-feature.md`) surfaces content-team metadata like difficulty/confusing/importance directly on the compass card, so a struggling student sees "this chapter is tagged Hard + Confusing" next to their own weak stats — context they don't currently get anywhere.

`links` gives the frontend ready-made deep links into the existing Practice/Formula/Lecture screens scoped to that node, rather than requiring the frontend to re-derive query params — exact param shape is an implementation detail for engineering to finalize against the real Practice/Formula list endpoints, not a product decision.

### 8.3 Definition of "progress" per content type

To keep this predictable and consistent with existing behavior elsewhere in the product:

**Video** — identical to `/lecture/subject-progress`'s existing logic (`docs/lecture-plan-feature.md`):
- `done: true` → **done**
- `done: false` → **skipped** (folded into `notStarted` for Compass's simpler 3-bucket view, or kept separate — TBD, see §9)
- `done: null`, `seen > 0` → **inProgress**
- otherwise → **notStarted**

**Practice question** — status is per (user, question), using the **most recent** `UserPracticeAnswer` across all the student's attempts at that question (not first-attempt, unlike the admin analytics in `docs/practice-dashboard-api.md`, which deliberately use first-attempt for diagnostic/cohort purposes). Compass is a "how am I doing *right now*" view, so the latest answer is the correct signal — a student who got a question wrong once and right on a retry should see it as mastered, not as a historical miss.
- No `UserPracticeAnswer` row exists at all → **unattempted**
- Latest answer `isCorrect: true` → **correct**
- Latest answer `isCorrect: false` → **wrong**
- `attempted` = `correct + wrong` (any question with at least one answer)

**Formula** — same "latest attempt" rationale, using `FormulaToUser` (one row per attempt, `isRight` boolean):
- No `FormulaToUser` row → **unattempted**
- Most recent row `isRight: true` → **mastered**
- Most recent row `isRight: false` → **needsReview**

**Scope of "total"** — deliberately **all** tagged content regardless of `VideoInfo.importance`, unlike `/lecture/subject-progress` which counts `required`-only videos (because that endpoint feeds the Study Plan scheduler, which only ever schedules `required` items). Compass is a browse/discovery surface, not a scheduler, so `recommended` and `optional` content should count too — otherwise a student who dutifully watches "optional" bonus content sees it vanish from their own progress view. Flagged as a product decision to confirm before build (see §9).

### 8.4 Blended `overallPercent`

A single number per subject/chapter, for the progress bar/ring in the UI. Proposed formula, to be confirmed with product/design before implementation:

```
overallPercent = round(
  ( (video.done            / max(video.total, 1))
  + (practice.correct      / max(practice.total, 1))
  + (formula.mastered      / max(formula.total, 1))
  ) / countOfNonEmptyContentTypes  × 100
)
```

Where `countOfNonEmptyContentTypes` excludes a content type whose `total` is `0` for that node (a chapter with no formulas shouldn't be dragged down by a phantom 0% formula score). A node with `total: 0` across all three types shows `overallPercent: null` and should be visually greyed out rather than shown as "0%" — same treatment `/lecture/subject-progress` already applies to empty leaf nodes.

This is a v1 placeholder, not a locked spec — see §9 for the alternative (weight by content-type importance rather than equal thirds).

### 8.5 Course resolution

Resolve the student's course the same way the rest of the lecture module already does: the `watching_course_${userId}_${platformId}` Redis cache key set when the student opens/starts a course (see `docs/lecture-plan-feature.md`), **not** a client-supplied `courseId`. This is a deliberate consistency choice: it matches every other student-facing endpoint in the lecture module, and avoids reintroducing the exact class of bug described in `docs/bug-report-student-portal-course-overview.md` (Bug 2 — a client-supplied course identifier that goes stale or mismatches on course switch). If nothing is cached, return `400` with `"You are not watching any course"`, matching existing behavior.

If the resolved course has a `CourseOption` with `key = 'templateCourseId'`, resolve subjects/content under that template course instead — same indirection `findAll`/`findLecture`/`buildSchedule` already apply (`docs/lecture-plan-feature.md`), since content is frequently shared across several enrolled child courses via one template course.

### 8.6 Cross-links to Study Plan

Where relevant, a chapter node's `video` block should be able to answer "is this on my study plan and when" — at minimum, the frontend should be able to cross-reference a video's `videoId` (exposed once we get to leaf content, see §8.2 `links`) against `/lecture/subject-progress` or `/lecture/next`/`/lecture/week` to show a "Scheduled for Thursday" hint on a not-yet-done video inside Chapter Compass. This is a nice-to-have composition of two existing/new endpoints, not a new field Compass itself needs to compute — flagged for the frontend integration phase, not backend scope.

## 9. Open questions / decisions needed before build

| # | Question | Recommendation | Owner |
|---|---|---|---|
| 1 | Should `skipped` videos (`done: false`) be their own bucket in Compass, or folded into `notStarted`? | Keep separate — a student who explicitly skipped shouldn't look identical to one who never started; costs nothing extra since the source data already distinguishes them. | Product |
| 2 | Should `total` include `optional`/`recommended` videos, or `required`-only like the Study Plan? | Include all — see §8.3 rationale. | Product |
| 3 | Is "latest attempt" the right mastery signal for practice/formula, or should Compass weight by attempt history (e.g. 3-in-a-row correct = mastered)? | Ship "latest attempt" for v1 — simplest, matches the "how am I doing now" framing; revisit if it produces confusing "flip-flop" behavior in practice. | Product |
| 4 | Should quiz performance (`QuizQuestiontoFallNumber`) and doubt-forum activity (`DoubtQuestion`) be folded into Compass? | Defer to v1.1 — the join is straightforward (same `FallNumber` pattern) once video/practice/formula ships and the UI pattern is validated. | Product |
| 5 | Is the equal-thirds `overallPercent` formula (§8.4) right, or should content types be weighted (e.g. practice weighted higher since it's the strongest mastery signal)? | Ship equal-thirds for v1, instrument, revisit with real usage data. | Product/Design |
| 6 | How deep does the UI actually render the `CourseSubject` tree — stop at chapter, or go to LOS/topic level too? | Support the full tree in the API (already order-sorted, already implemented for lectures); let frontend decide render depth per course based on how deep that course's syllabus actually goes. | Design |
| 7 | Cap on subjects per course for Subject Compass pagination? | Unlikely needed — course subject counts are typically small (tens, not hundreds) based on existing `CourseSubject` usage; confirm no pathological courses exist before assuming unpaginated is safe. | Engineering |

## 10. Implementation notes (for engineering, non-binding)

- Suggest a new lightweight module (`src/compass/`) rather than bolting this onto `lecture`, `practice`, or `formula` — it's a read-only aggregator across all three and doesn't own any of their data. Follow the standard module shape from `docs/user-api-guide.md` (`PlatformCheckMiddleware` wired, `DatabaseModule` imported, registered in `app.module.ts`).
- Two endpoints roughly matching this PRD's two screens:
  - `GET /compass/subjects` — Subject Compass, `AuthGuard`, no params (course resolved per §8.5).
  - `GET /compass/subjects/:subjectId/chapters` — Chapter Compass, `AuthGuard`, `subjectId` must be a root subject the resolved course actually has (`404` otherwise).
- The recursive rollup logic in `LectureService.getSubjectProgress` (`docs/lecture-plan-feature.md`) is the closest existing precedent for walking the `CourseSubject` tree and summing descendant counts — reuse/extract that traversal rather than reimplementing it, then extend it to also join `UserPracticeAnswer`/`FormulaToUser` per `FallNumber` at each node.
- Practice/formula counts need one query per content type scoped to the resolved course's `FallNumber`s (via `FallNumberToCourse`), then grouped by the `FallNumberToSubject` mapping — mirrors how `docs/practice-admin-api.md`'s `courseId` filter already works (`?courseId=` filters "questions whose fall numbers are mapped to this course").
- Keep both endpoints read-only and reasonably cheap: this is a dashboard a student may open often (before every exam), so avoid N+1 queries per tree node — batch-fetch all relevant `UserToVideoInfo` / `UserPracticeAnswer` / `FormulaToUser` rows for the course up front (same pattern `getSubjectProgress` already uses) and aggregate in memory rather than per-node round trips.

## 11. Success metrics

- % of active students who open Subject Compass at least once per week during an active study period.
- % of Subject Compass sessions that proceed into a Chapter Compass drill-down (signals the summary alone isn't sufficient — validates the two-screen structure).
- Change in practice-question attempt rate for chapters where a student's video-done / practice-unattempted gap was visibly surfaced by Compass, vs. chapters not yet viewed in Compass (does surfacing the gap actually close it?).
- Support/ticket volume referencing "can't see my progress" or "readiness not showing" (relates to `docs/bug-report-student-portal-course-overview.md` Bug 3) — should trend down if Compass becomes the primary progress surface.

## 12. Related docs

- `docs/lecture-plan-feature.md` — `GET /lecture/subject-progress` is the direct precedent this feature generalizes; also owns the Study Plan that Compass should cross-link to (§8.6).
- `docs/course-models.md` — `CourseSubject` / `Course` schema background.
- `docs/practice-admin-api.md`, `docs/formula-admin-api.md`, `docs/lecture-video-admin-api.md` — how content gets tagged with `FallNumber` in the first place (admin side); no changes needed here for this feature.
- `docs/bug-report-student-portal-course-overview.md` — existing student-portal progress/readiness surface this feature is positioned to eventually replace; informs the course-resolution requirement in §8.5.
