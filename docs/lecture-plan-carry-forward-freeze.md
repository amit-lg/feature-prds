# Study Plan — Freezing Carry-Forward

Implementation reference for making the study plan's carry-forward a persisted
commitment rather than a value recalculated on every request.

**Status:** design agreed in principle; product decisions still open (see
[Open decisions](#13-open-decisions)). No code written yet for the freeze
itself. One separate requirement — a carried-forward lecture staying visible in
the week that planned it — has been implemented against the current unfrozen
builder; see [section 15](#15-carry-forward-visibility-at-the-origin-week).

**Related:** [`docs/lecture-plan-feature.md`](docs/lecture-plan-feature.md) —
the existing behavioural writeup of the feature as it stands today.

---

## Table of contents

1. [The problem](#1-the-problem)
2. [How it works today](#2-how-it-works-today)
3. [Why it breaks](#3-why-it-breaks)
4. [What we are changing](#4-what-we-are-changing)
5. [Side by side](#5-side-by-side)
6. [Database changes](#6-database-changes)
7. [Storage sizing and alternatives](#7-storage-sizing-and-alternatives)
8. [Behaviour of plan edits](#8-behaviour-of-plan-edits)
9. [Behaviour of course content changes](#9-behaviour-of-course-content-changes)
10. [Rollout sequence](#10-rollout-sequence)
11. [Performance impact](#11-performance-impact)
12. [Restrictions and risks](#12-restrictions-and-risks)
13. [Open decisions](#13-open-decisions)
14. [Code touchpoints](#14-code-touchpoints)
15. [Carry-forward visibility at the origin week](#15-carry-forward-visibility-at-the-origin-week)

---

## 1. The problem

A student in week 5 with 60 hours of backlog is asked to complete week 5's own
content plus a portion of that backlog as catch-up. They complete all of it.
They refresh the page and the week reports as incomplete again, with the same
amount of catch-up still outstanding.

This repeats indefinitely. As long as any backlog exists anywhere in the plan,
the current week refills itself to its ceiling on every request, so there is no
amount of work that closes the week. The student is effectively being asked for
unlimited hours, which is the opposite of the cap they configured.

The requirement: carry-forward must be as fixed as the weekly plan itself, and
a student must never be asked to cover more of the course than the limit they
set.

---

## 2. How it works today

### In plain terms

The database stores only the five values the student submitted: hours available
per day, buffer days, revision days, exam date, and start date. That is all.
There is no stored schedule, no stored weeks, and no stored carry-forward
figures.

Everything the student sees is calculated fresh every time a page loads. The
system holds no state between requests, which means **it cannot remember what it
told the student a moment ago.** That single fact is the origin of every problem
in this document.

### The steps taken on every request

1. Read the plan settings.
2. Read the entire course content tree — lectures, video durations, subject and
   chapter hierarchy.
3. Read the student's progress rows for every video on the course.
4. Build an "ideal" weekly plan from scratch: walk forward day by day from the
   start date, fill each day up to its hour quota, split any lecture longer than
   a day's quota across consecutive days. This determines which week each lecture
   belongs to.
5. Identify backlog: any lecture still unfinished whose assigned week has already
   ended. Spread it forward over the coming weeks, filling only capacity the
   ideal plan has not already used.
6. Total up how many hours each already-finished week failed to deliver, pool
   those hours together, and pour the pool into the current week first (up to
   that week's spare capacity), spilling the remainder onto later weeks.

Steps 4 through 6 are pure in-memory arithmetic and run again from zero on every
request.

### Rules as currently implemented

- A week runs Sunday to Saturday, anchored on the Sunday on or before the plan's
  start date.
- A lecture's deadline is the **end of its assigned week** (Saturday), not a
  specific day within that week.
- A day's capacity for catch-up is `min(day's pledged hours × 1.5, 12h)`, minus
  whatever the ideal plan already placed there. A rest day (zero pledged hours)
  absorbs no catch-up at all.
- A week's shortfall is `planned − completed − skipped`. Skipped time is not
  treated as debt, but is also not treated as study time.
- Completion is credited to the week that **originally planned** a lecture.

### Two separate builders exist

Worth knowing before touching anything. There are two independent schedulers:

- **The live forward walk.** Starts at whichever is later, today or the start
  date, discards everything already finished, and re-lays the remaining lectures
  forward. A rolling estimate. Weeks here are just slices of that walk and shift
  every day. Behind `GET /plan`, `GET /plan/weeks`, `GET /week`, `GET /next`.
- **The fixed-week builder.** Builds the ideal weekly grid, then cascades only
  the lectures that missed their week. Behind `GET /plan/weeks/v2`,
  `GET /week-overview`, `GET /progress-summary`.

Carry-forward exists only in the second one. This document concerns that builder
only.

---

## 3. Why it breaks

### Worked example

Student pledges 4 hours a day, every day. A week therefore plans 28 hours. Day
ceiling for catch-up is `min(4 × 1.5, 12) = 6h`, so the week's ceiling is 42
hours, leaving 14 hours of room for backlog on top of its own 28.

Student is in week 5 with 60 hours of backlog accumulated from weeks 1–4.

| Step | Result |
| --- | --- |
| Week 5 calculated | 28h own content + 14h catch-up = **42h target** |
| Student completes all 42h | Every assigned lecture finished |
| Student refreshes | Recalculation runs from scratch |
| Credit for the 14h of catch-up | Goes to weeks 1–4, because those weeks originally planned those lectures |
| Backlog pool | Correctly drops 60h → 46h |
| Week 5 recalculated | Still has 14h of room; pool is still non-empty; **14h poured in again**, pulled back from week 6 |
| Week 5 now reports | 42h target, 28h completed, **14h outstanding** |

The student did 42 hours of work and the week still shows incomplete. Every
subsequent refresh does the same thing.

### Root causes

Two independent faults combine:

**Credit is attributed to the wrong week.** Work performed as catch-up during
week 5 is credited to the week that originally planned the lecture, so week 5
receives nothing for it. Week 5's completed figure can only ever reach its own
28 hours.

**The demand is recalculated rather than remembered.** Because "week 5 owes 14
hours of catch-up" was never written down, the system cannot distinguish
"already asked, and it was delivered" from "not yet asked". It simply recomputes
the week's ceiling on every request.

### The same fault in the lecture list

The hour totals are not the only symptom. Once a student finishes a backlog
lecture it leaves the pending queue, so the next unwatched backlog lecture is
pulled forward into the current week. Clear the visible catch-up list, refresh,
and new lectures appear in it.

### Further problems from the same root cause

- **Editing the plan rewrites the past.** Changing daily hours re-lays the ideal
  plan from the start date using the new hours, so lectures land in different
  weeks than before. Weeks the student has already lived through are
  retroactively described differently, and carry-forward is recalculated against
  a different history. This is the observed symptom of the current week's
  carry-forward changing on plan update.
- **Editing the start date renumbers every week,** because the Sunday anchor is
  derived from it.
- **Course content changes reshuffle history.** Adding a lecture, removing one,
  or correcting a video's duration shifts everything after it into different
  weeks, including weeks already elapsed.
- **No history exists.** There is no way to answer "was week 3 completed" or
  "what was this student asked to do in week 3". Only the current derived guess
  exists.

---

## 4. What we are changing

The single idea: **the demand becomes a written commitment instead of a
calculation.**

When a week begins, the system decides once — "this week owes its own planned
content plus these specific lectures as catch-up" — writes that down, and never
revises it for that week. Every later request reads the record back instead of
recalculating.

### The three mechanisms

**1. Freeze the ideal plan.** Persist which lecture, and which slice of it,
belongs to which week and day. The carry-forward cannot be frozen while the
yardstick it is measured against is still recalculated.

**2. Open each week exactly once.** The moment a week becomes current, compute
its catch-up allocation one time:

```
capacity   = week's ceiling − week's own planned content
carryIn    = outstanding debt at this moment
assigned   = min(carryIn, capacity)
```

Select the specific backlog lecture segments that fill `assigned`, in course
order, and record them against that week. From then on the week's target is
fixed — it cannot grow, cannot be refilled, cannot be re-selected.

**3. Close each week exactly once.** When a week ends, record what it planned,
what was completed, what was skipped, what catch-up it had been assigned, how
much of that catch-up was delivered, and the resulting shortfall and outstanding
debt. Write once, never revise, never recompute.

### The rule change that fixes the bug

**Catch-up work is credited to the week that assigned it.** Because the assigned
lectures are recorded against week 5, watching them settles week 5. Weeks 1–4
are closed and their shortfall is already recorded as historical fact, so they no
longer re-absorb the credit and the debt figure no longer resets.

Debt becomes a recorded running total, decremented when assigned catch-up is
delivered, rather than something re-derived by re-scanning all elapsed weeks.
Removing that re-scan is what stops the treadmill.

### Consequences

- **A week becomes completable.** Its own content plus its assigned catch-up,
  both resolved, means done — and it stays done across refreshes, because there
  is nothing left to recompute.
- **Only the current week is committed.** Weeks beyond it remain a forecast, are
  free to move, and are committed one at a time as each becomes current. This
  shows the student a realistic road ahead without locking in weeks of plan that
  their own progress will invalidate. Future weeks should be labelled as
  projections in the API response so clients can present them differently.
- **The cap is enforced structurally.** A week's target is the committed figure,
  not a ceiling re-derived on every read.

### What does *not* need to change

Whether the student actually watched an assigned lecture stays **derived** from
the existing progress rows, exactly as today. It becomes stable automatically,
because the assignment it is measured against no longer moves.

This is an important scope reduction: **the code that records watch progress does
not change at all.** No hooks, no additional writes on a hot path. Only the
commitment is persisted, not the fulfilment.

---

## 5. Side by side

| | Today | Proposed |
| --- | --- | --- |
| The ideal weekly plan | Recalculated every request | Stored once, per lecture ([detail](#51-the-ideal-weekly-plan)) |
| How much catch-up this week owes | Recalculated every request, always up to the ceiling | Decided once when the week starts, then read back ([detail](#52-how-much-catch-up-this-week-owes)) |
| Who gets credit for catch-up work | The week the lecture originally belonged to | The week that assigned it |
| Backlog total | Re-derived by re-scanning every finished week | A recorded figure, updated when a week closes |
| Finished weeks | Do not exist as records | Sealed, immutable |
| Future weeks | Indistinguishable from the current week | Explicitly labelled projections |
| Effect of editing the plan | Rewrites every week, past and present | Affects future weeks only |
| Effect of editing the start date | Renumbers every week | Rejected, or treated as a plan reset |
| Effect of a course content change | Reshuffles every week, past included | Future weeks only |
| Can a week be completed | No — refills to the ceiling forever | Yes, and it stays completed |
| History available | None | Full per-week record |
| Progress-write path | — | Unchanged |

The first two rows are the substance of the change; the rest follow from them.
Both deserve their own explanation.

### 5.1 The ideal weekly plan

**What it is.** The answer to "which week is this lecture supposed to be
covered in". It is a full layout of the entire course across calendar weeks,
built by walking forward from the start date and filling each day to the
student's pledged hours, splitting any lecture too long for one day across
consecutive days. It assumes the student does everything on time and ignores
their actual progress entirely.

**Why it exists.** It is the yardstick. Everything else in the feature is
measured against it: a lecture is "late" because its assigned week has ended; a
week's `planned` hours are what this layout put in that week; the backlog is
whatever this layout said should already be finished but is not. It is not
itself a to-do list — it is the reference the to-do list is derived from.

**Today.** Rebuilt from scratch on every request, from the *current* daily hours
and the *current* course content. Two consequences:

- Change your daily hours from 4 to 6 and the entire layout is redrawn from the
  start date. Lectures that were in week 3 may now be in week 2. Weeks the
  student already lived through are now described differently than they were
  described at the time.
- Add a lecture to the course, remove one, or correct a video's duration, and
  everything after it shifts into different weeks — again including elapsed
  weeks.

Because the yardstick moves, every measurement taken against it moves too. This
is why the carry-forward shifts on a plan edit even for the current active week.

**Proposed.** Resolved once and persisted, as a concrete list: this lecture, this
slice of it (start and end second), this week, this day. Once written, plan edits
and content edits cannot reach backwards into it. Edits apply to weeks not yet
opened; elapsed and current weeks keep the layout they were actually given.

**Why it must come first.** Freezing the carry-forward on top of a moving
yardstick would produce records that disagree with the plan they were measured
against — a week sealed saying "you owed 28 hours" while the live layout now says
that week only ever planned 19. The two changes cannot be separated.

### 5.2 How much catch-up this week owes

**What it is.** The extra hours of overdue work stacked on top of the current
week's own planned content, and the specific lectures making up those hours. In
the API response this is the `carriedOver` figure sitting next to `planned`, and
the day items flagged as carried over.

**How the amount is decided.** Two inputs. First, the outstanding debt — the sum
of what every finished week failed to deliver. Second, the week's room: its
ceiling (each study day pushed to 1.5× its pledge, capped at 12 hours) minus
whatever its own planned content already occupies. The week takes the smaller of
the two; anything left over spills onto the following weeks. The split is
deliberately front-loaded rather than even, so the student catches up as early as
their own pledged hours allow.

**Today.** Recalculated on every request, and the current week is always first
in line for the pool. This produces the failure in [section 3](#3-why-it-breaks):
because the completion of a carried lecture is credited to the week that
originally planned it, the current week's own completed figure never grows to
cover the catch-up it was handed. The debt shrinks correctly, but the current
week simply refills from the next week's share to reach its ceiling again. The
week's demand is therefore permanently equal to its ceiling, not to
"what was assigned, minus what was delivered".

The lecture list behaves identically. Finished backlog lectures drop out of the
pending queue and the next unwatched ones are pulled forward to take their place,
so the visible catch-up list regenerates itself as fast as the student clears it.

**Proposed.** Computed once, at the moment the week becomes current, and written
down — both the hour figure and the specific lecture segments. Subsequent
requests read that record. The consequences:

- The figure cannot grow. A week that was told "14 hours" owes 14 hours for its
  whole duration, regardless of what happens to the debt total elsewhere.
- The lecture list cannot regenerate. The same segments stay listed until they
  are resolved.
- Completing them credits *this* week, because they are recorded against this
  week. So the week's outstanding figure actually falls to zero and stays there.
- The student is never asked for more than the limit their own pledged hours
  imply, because the limit is a committed number rather than a ceiling re-derived
  on every read.

**What this deliberately gives up.** A student who clears their committed
catch-up early cannot automatically absorb more from later weeks. That automatic
pulling-forward *is* the bug, so it cannot be preserved. If pulling forward is
wanted it has to become an explicit student action — see
[open decision 2](#13-open-decisions).

---

## 6. Database changes

Shapes below reflect the **recommended** storage strategy from
[section 7](#7-storage-sizing-and-alternatives): **every value is a real column in
a real table.** No document payloads. The only `Json` columns are the two that
hold the student's own free-form hours map, which is already a `Json` column on
the existing model.

Section 7 sizes this honestly — the frozen ideal plan is a large table — and
documents a `Json`-column variant as an alternative if that sizing ever becomes a
problem.

### 6.1 New columns on `UserCourseStudyPlan`

```prisma
week1Start          DateTime    // frozen Sunday anchor, set once at creation
baselineTotalWeeks  Int?
baselineBuiltAt     DateTime?
timezone            String?     // week boundaries now trigger writes
lastClosedWeek      Int      @default(0)
```

`week1Start` is the load-bearing addition. The Sunday anchor is currently derived
from `startDate`, so editing the start date renumbers every week retroactively.
Freezing the anchor removes that.

`lastClosedWeek` is a convenience pointer — derivable from the week table, but it
saves a query on every read.

**This forces a decision on `startDate`:** it becomes effectively immutable after
creation, because changing it renumbers weeks and invalidates every stored
record. Either reject the change in the update path, or treat it as a full plan
reset. It can no longer be a silent field update.

### 6.2 `UserStudyPlanBaseline` — the frozen ideal plan

One row per planned lecture segment. A lecture that fits inside a single day has
one row; a lecture split across three days has three.

```prisma
model UserStudyPlanBaseline {
  id             Int      @id @default(autoincrement())
  studyPlanId    Int
  videoId        Int
  weekNumber     Int
  scheduledDate  DateTime // the day inside that week
  startSecond    Int
  endSecond      Int
  segmentIndex   Int
  totalSegments  Int

  // denormalised so the recursive content join leaves the read path;
  // see 7.2 and Performance impact
  subjectLeafId  Int?

  createdAt      DateTime @default(now())

  StudyPlan UserCourseStudyPlan @relation(fields: [studyPlanId], references: [id], onDelete: Cascade)
  Video     VideoInfo           @relation(fields: [videoId], references: [id])

  @@unique([studyPlanId, videoId, segmentIndex])
  @@index([studyPlanId, weekNumber])
  @@index([studyPlanId, scheduledDate])
}
```

Every value is a named, typed column — readable in `psql`, queryable, and with a
foreign key on `videoId` so a deleted lecture cannot leave a dangling reference.

`scheduledDate` stores the actual date rather than an offset from `week1Start`,
so a row means something on its own without knowing the anchor.

**On `subjectLeafId`.** This is the one denormalised field, and it is deliberately
an identifier rather than the resolved subject path. Storing the full path here
would repeat roughly 270 bytes across every row; storing the leaf identifier costs
4 bytes and is enough, because the course's subject nodes are a small set that can
be fetched in one cheap flat query and assembled into paths in memory. That
removes the expensive recursive join from the read path without widening this
table — see [Performance impact](#11-performance-impact).

Lecture names are resolved the same way: a flat, non-recursive lookup scoped to
the course, not a stored copy per row.

### 6.3 `UserStudyPlanWeek` — one row per week

Created when the week **opens** (recording the commitment); sealed when the week
**closes** (recording what was delivered). This table is the core of the fix, and
the only genuinely row-per-entity table being added.

```prisma
model UserStudyPlanWeek {
  id          Int      @id @default(autoincrement())
  studyPlanId Int
  weekNumber  Int
  weekStart   DateTime
  weekEnd     DateTime

  // written at OPEN — the commitment, never revised
  plannedSeconds         Int   // the week's own hours, from the frozen layout
  capacitySeconds        Int   // room for catch-up, snapshotted for audit
  carryInSeconds         Int   // debt outstanding when this week opened
  assignedCatchUpSeconds Int   // = min(carryIn, capacity) — the contract

  // written at CLOSE — what actually happened
  completedOwnSeconds     Int?
  skippedOwnSeconds       Int?
  completedCatchUpSeconds Int?
  skippedCatchUpSeconds   Int?
  shortfallSeconds        Int?
  carryOutSeconds         Int?  // debt outstanding after this week

  status   String   // 'open' | 'closed'
  openedAt DateTime @default(now())
  closedAt DateTime?

  StudyPlan    UserCourseStudyPlan        @relation(fields: [studyPlanId], references: [id], onDelete: Cascade)
  CatchUpItems UserStudyPlanCatchUpItem[]

  @@unique([studyPlanId, weekNumber])
  @@index([studyPlanId, status])
}
```

**The unique constraint on `(studyPlanId, weekNumber)` is the concurrency
guard.** Two parallel requests both crossing into a new week: one insert wins,
the other fails the constraint, catches the error, and re-reads the winner's row.
No explicit locking required.

`carryOutSeconds` on the most recent closed row is the **single source of truth**
for outstanding debt. Do not also keep a running balance on the plan row — two
places to drift.

The `completed*` fields stay null while a week is open; current-week figures are
computed live from progress rows and only sealed at close.

`status` is a `String` rather than an enum to match the existing schema, which
uses exactly one enum across roughly 3,300 lines.

### 6.4 `UserStudyPlanCatchUpItem` — the committed catch-up lectures

The record support staff and developers will actually read — "what was this
student asked to do in week 5" — and the one most likely to need a relational
query later, such as which students still owe a particular lecture.

```prisma
model UserStudyPlanCatchUpItem {
  id               Int      @id @default(autoincrement())
  studyPlanWeekId  Int
  videoId          Int
  startSecond      Int
  endSecond        Int
  segmentIndex     Int
  totalSegments    Int
  originWeekNumber Int      // for display: "carried over from week 2"
  createdAt        DateTime @default(now())

  Week  UserStudyPlanWeek @relation(fields: [studyPlanWeekId], references: [id], onDelete: Cascade)
  Video VideoInfo         @relation(fields: [videoId], references: [id])

  @@unique([studyPlanWeekId, videoId, segmentIndex])
  @@index([videoId])
}
```

Written once at week open, in the same transaction as the parent week row. Never
revised for that week.

`originWeekNumber` is stored rather than resolved from the layout so the UI can
label where a carried lecture came from without a lookup.

Display strings are deliberately **not** repeated here — resolve them the same way
the baseline rows do, from the lookups already loaded on the same request.

**Optional phase-two additions**, for reporting only and not required for
correctness: `settledAt`, `settlementType` (`'completed' | 'skipped' | 'partial'`),
`settledSeconds`. Skip in phase one — settlement is derived from progress rows.

### 6.5 `UserStudyPlanRevision` — audit of plan edits (recommended)

Not required for correctness, but valuable for support. The whole point of this
change is that edits no longer rewrite history, so "why does my plan look
different from last week" becomes a question someone will ask.

```prisma
model UserStudyPlanRevision {
  id                Int      @id @default(autoincrement())
  studyPlanId       Int
  dailyHours        Json
  bufferDays        Int
  revisionDays      Int
  examDate          DateTime?
  effectiveFromWeek Int
  createdAt         DateTime @default(now())

  StudyPlan UserCourseStudyPlan @relation(fields: [studyPlanId], references: [id], onDelete: Cascade)

  @@index([studyPlanId])
}
```

### 6.6 Cascade semantics

Every new table cascades from the plan row, so deleting a plan wipes its history.
If debt history should survive a plan reset, the week and revision tables need to
detach from cascade instead. Decide this before writing the migration.

---

## 7. Storage sizing and alternatives

### 7.1 Which table would have five million rows

Only one: a **row-per-segment `UserStudyPlanBaseline`** — the frozen ideal plan
stored as one row per planned lecture segment. That was the shape in the first
draft of this document, and it is the reason for the figure.

The arithmetic: roughly 400 required lectures on a large course, plus extra
segments for lectures long enough to split across days, gives around 500 rows per
student per course. At 10,000 active plans that is about 5 million rows.

Estimated on-disk cost for that shape:

| Variant | Rows | Approx. size incl. indexes |
| --- | --- | --- |
| Row-per-segment, identifiers only | ~5.2M | ~800 MB |
| Row-per-segment, with display fields denormalised | ~5.2M | ~2.2 GB |

The second row is the problem. Denormalising lecture names and subject paths is
what delivers the performance win, but repeating a ~270-byte subject path across
5 million rows to get it is a poor trade.

No other table in the design approaches this. For completeness:

| Table | Rows per plan | At 10,000 plans |
| --- | --- | --- |
| `UserStudyPlanWeek` | ~40 (one per week) | ~400,000 |
| `UserStudyPlanRevision` | a handful | tens of thousands |
| `UserStudyPlanCatchUpItem` | up to ~100 for a chronically behind student | up to ~1M |

The catch-up table scales with how far behind students are — a student on track
accumulates almost no rows, one behind for most of their plan gets a committed
list every week. Even at the pessimistic end it stays around a million rows,
which is comfortable as a real table.

### 7.2 Why we are proceeding with real tables anyway

Five million rows is a large table but not a difficult one. Postgres handles it
without complaint given the indexes in [6.2](#62-userstudyplanbaseline--the-frozen-ideal-plan),
and the access pattern is always narrow — one plan, sometimes one week within it.

What the row shape buys:

- **The data is readable.** Anyone can open the table and understand it without a
  decoder. This matters more than the storage saving, because these records are
  the audit trail for a student-facing commitment; support will read them.
- **Referential integrity.** A foreign key on `videoId` means a deleted lecture
  cannot leave a dangling reference to be silently skipped later.
- **Queryable.** "Which students have lecture X scheduled in week 3", "how many
  plans still reference a retired lecture" — indexed queries rather than
  application-level scans over documents.
- **Partial rebuild is a single statement.** A plan edit becomes
  `DELETE ... WHERE studyPlanId = ? AND weekNumber > ?` followed by an insert. No
  read-modify-write, so no lost-update race between two concurrent edits — a
  document rewrite has one and would need handling.
- **Cheap incremental change.** Adding one new lecture to a future week inserts
  one row instead of rewriting a 100 KB payload.

**Avoid the 2.2 GB variant.** The size table above shows the cost of denormalising
resolved subject paths onto every row. Do not do that. Store `subjectLeafId`
instead and assemble paths in memory from a small per-course subject fetch. That
keeps the performance win and holds the table at roughly 800 MB.

**Resulting footprint:**

| Table | Rows at 10,000 plans | Approx. size |
| --- | --- | --- |
| `UserStudyPlanBaseline` | ~5.2M | ~800 MB |
| `UserStudyPlanWeek` | ~400,000 | ~40 MB |
| `UserStudyPlanCatchUpItem` | up to ~1M | ~150 MB |
| `UserStudyPlanRevision` | tens of thousands | negligible |

Roughly a gigabyte in total. Worth revisiting if active plans grow by an order of
magnitude — at which point [7.3](#73-alternative-the-ideal-plan-as-a-json-column)
is the escape hatch.

### 7.3 Alternative: the ideal plan as a `Json` column

Documented as a fallback, **not the current recommendation.** Reach for it only if
the row count in `UserStudyPlanBaseline` becomes a genuine operational problem —
it is the one table where the volume is non-trivial, and it is also the one table
that nothing queries relationally, so it is the natural candidate.

The change: replace the row-per-segment table with a 1:1 side table holding one
document per plan.

```prisma
model UserStudyPlanBaseline {
  id          Int      @id @default(autoincrement())
  studyPlanId Int      @unique
  totalWeeks  Int
  layout      Json
  builtAt     DateTime @default(now())
  updatedAt   DateTime @updatedAt

  StudyPlan UserCourseStudyPlan @relation(fields: [studyPlanId], references: [id], onDelete: Cascade)
}
```

A side table rather than a column on `UserCourseStudyPlan`, so the narrow,
frequently-read plan row is not carrying a large payload most queries do not want.

If this route is taken, **every value must sit behind a named key.** Positional
tuples would save on the order of 40 MB in exchange for stored data nobody can read
without this file open alongside it — never worth it, and repeated key names
compress well under TOAST in any case, so the real saving is far below the raw byte
difference.

```jsonc
{
  "version": 1,

  // videoId -> display fields, resolved once at build time.
  // Separated from `segments` because a split lecture would otherwise repeat
  // its whole subject path on every one of its segments.
  "lectures": {
    "8821": {
      "lectureName": "Time Value of Money",
      "fallNumber": "FN-102",
      "subjects": [
        { "id": 41, "name": "Quantitative Methods", "type": "subject" },
        { "id": 92, "name": "Discounted Cash Flow", "type": "chapter" }
      ]
    }
  },

  "segments": [
    {
      "videoId": 8821,
      "weekNumber": 1,
      "date": "2026-06-21",
      "startSecond": 0,
      "endSecond": 14400,
      "segmentIndex": 1,
      "totalSegments": 2
    },
    {
      "videoId": 8821,
      "weekNumber": 1,
      "date": "2026-06-22",
      "startSecond": 14400,
      "endSecond": 21600,
      "segmentIndex": 2,
      "totalSegments": 2
    }
  ]
}
```

Note that a document can afford the full resolved subject path, because it is
stored once per lecture rather than once per segment — so this variant does not
need the `subjectLeafId` indirection.

**What it wins:** 10,000 rows instead of 5.2M, roughly 150 MB instead of 800 MB,
and the display fields can be embedded outright.

**What it costs:**

- No foreign key on `videoId`; a deleted lecture leaves a dangling identifier, to
  be skipped the way the current builders already skip an unresolvable video.
- No SQL queries by week or by video. If reporting needs that later, add a narrow
  derived index table alongside rather than normalising the layout back out.
- Partial rebuild becomes read-modify-write, so two concurrent plan edits can lose
  one another's changes. Needs a version column or a row lock.
- The whole document is rewritten on any change, including adding a single lecture.

Applying the same reasoning to `UserStudyPlanCatchUpItem` is **not** worth it: at
up to ~1M rows the table costs about the same as embedding the items in the week
row (~150 MB either way), so embedding buys nothing and loses readability and
queryability.

### 7.4 Other options considered

**Freeze the inputs instead of the output.** The layout is produced by a pure
function of (ordered lecture list with durations, daily hours, start date). Freeze
those inputs — including a snapshot of the ordered lecture list — and the output
is stable without persisting it. Storage drops to a few kilobytes per plan.

Correctness-wise this is sound, and it is worth understanding *why*: the
requirement is stability, not persistence. A pure function over frozen inputs is
stable. However it keeps the layout arithmetic on the read path and, more
importantly, gives up the denormalised display fields, which is where the real
performance win lives. Reasonable fallback if storage ever becomes the binding
constraint; not the first choice.

**Freeze only up to the current week.** Future weeks are explicitly projections
and free to move, so strictly only weeks up to and including the current one need
frozen data. A student in week 5 of a 40-week plan needs 5 weeks of layout, not
40. This roughly halves average storage and is compatible with either shape.

It is a real optimisation, and the most attractive one if the ~5.2M rows need
reducing without giving up the row shape. It does add a moving boundary to reason
about. Worth considering alongside
[7.3](#73-alternative-the-ideal-plan-as-a-json-column) rather than instead of it.

**Phase it: skip the frozen layout in phase one.** The reported bug is caused by
the *catch-up allocation* moving. The layout moving is a separate, secondary
problem — it is what makes plan edits rewrite history. So a smaller phase one is
possible: add the week rows and committed catch-up items only, and keep deriving
the layout as today.

That fixes the treadmill completely, with roughly 40 rows per plan and no large
table at all. What it does not fix: a plan edit still redraws the layout, so a
sealed week can end up disagreeing with the layout it was measured against. That
inconsistency is visible — the week says one thing, the lectures shown in it say
another.

**Recommendation:** do both in one change. The phased option is available if the
work needs to be split for delivery reasons, but the two halves are coupled
tightly enough that shipping only the first leaves a known inconsistency in
production.

---

## 8. Behaviour of plan edits

Depends on [open decision 1](#13-open-decisions). At the database level:

**If edits apply from the next week onward (recommended):**

- `DELETE` baseline rows where `weekNumber > currentWeek`, then insert the newly
  computed ones. Earlier weeks are left alone.
- Write a revision row with `effectiveFromWeek = currentWeek + 1`.
- Closed week rows: untouched.
- Current open week row: untouched.

Every field on an open week row stays write-once.

**If edits apply immediately:**

- As above, plus baseline rows for the remaining days of the current week are
  replaced.
- The current open week row's `plannedSeconds` and `capacitySeconds` must be
  updated.
- `carryInSeconds` and `assignedCatchUpSeconds`, and the week's catch-up item
  rows, must still **not** change — those are the commitment.

This makes the open week row partly mutable, weakening the "commitment is
immutable" invariant. That asymmetry is the main argument for the first option.

In both cases the outstanding debt figure carries across the edit unchanged.

---

## 9. Behaviour of course content changes

Once the layout is frozen, content edits cannot reshuffle past weeks. Explicit
rules are needed for lectures that have no baseline row, or the plan will silently
ignore them forever:

- **New required lecture** → insert baseline rows into the first week not yet
  opened.
- **Lecture removed from the course** → delete its baseline rows for
  not-yet-opened weeks. Leave rows in closed weeks alone as historical fact.
- **Duration corrected** → treat as removal plus re-add, for not-yet-opened weeks
  only.
- **Lecture renamed** → nothing to do. Names are resolved on read rather than
  stored per row, which is one advantage of the row shape over the `Json`
  alternative in [7.3](#73-alternative-the-ideal-plan-as-a-json-column).
- **Subject re-parented** → nothing to do either, for the same reason: only the
  leaf identifier is stored, and the path is assembled on read.

---

## 10. Rollout sequence

`npm run build` runs `prisma migrate deploy` before building, so migrations apply
on deploy against `DATABASE_URL`. The ordering below matters.

1. **Migration.** Add all columns and tables. Every new column nullable or
   defaulted. Nothing reads them yet. Safe to deploy on its own; existing
   behaviour unchanged.
2. **Backfill script.** Run after the migration and before anything reads the new
   tables. Per active plan: build the layout with the existing logic and write the
   baseline rows; set `week1Start`; create closed week rows for every already
   elapsed week using the current derivation; create the open row plus committed
   catch-up items for the current week. Must be idempotent, chunked by plan, and
   resumable.
3. **Flag flip.** Switch the read path from deriving to reading stored data. Keep
   it behind a per-course or per-platform flag so it can be reverted without a
   rollback.
4. **Cleanup.** Once stable, make `week1Start` non-nullable and remove the
   derive-on-read fallback.

Backfilled closed weeks inherit the current derivation's quirks. This is
unavoidable — it is a seed. Every week after cutover is accurate.

---

## 11. Performance impact

This is a correctness fix, not a performance project. The effect is net positive
but modest, and its size depends on one design choice.

### Current cost per request

Roughly five database queries, one of which is heavy: a deeply nested join that
pulls the entire course content tree, including a four-level recursive walk of
the subject hierarchy. On top of that, substantial in-memory arithmetic — the
ideal plan is built in two passes over every lecture, the backlog spread is run
twice (a counting pass then a build pass), and the weekly totals walk every week
and every day within it. For a large course over a long horizon that is a few
hundred thousand small operations, repeated on every page load. The dashboard
endpoint runs the whole thing plus a separate reconstruction of the previous
week.

The heavy content join is almost certainly the dominant cost, not the arithmetic.

### What improves

All of the arithmetic disappears — the ideal plan, the backlog spread and the
weekly totals are read rather than computed. That is a real saving, but it is the
cheaper half of the cost. Two further gains: a request for a single week can read
just that week's row instead of building the entire horizon, and the dashboard
endpoint stops duplicating work.

### The choice that decides the size of the win

Responses need lecture names, subject paths and chapter numbers for display.

- **If those are still looked up,** the heavy content join stays on the read
  path. Only the arithmetic is saved — a meaningful CPU reduction, but the
  endpoint's slowest query is unchanged.
- **If the frozen layout carries `subjectLeafId`,** the recursive join leaves the
  read path entirely. A request becomes: the plan row, the week row, that week's
  baseline rows, that week's catch-up rows, a flat lecture-name lookup, and one
  small fetch of the course's subject nodes — from which the paths are assembled
  in memory. This is the large win.

**Recommendation: store `subjectLeafId`, resolve names and paths on read.** This
gets the join off the read path for 4 bytes per row rather than 270, and it has a
second benefit over storing resolved strings: a renamed lecture or a re-parented
subject needs no refresh path at all, because nothing is cached per row.

### New costs

- **Storage.** See [section 7](#7-storage-sizing-and-alternatives). Roughly 5.2M
  rows in the largest table and about a gigabyte in total, with a documented
  `Json` fallback if that ever needs reducing.
- **Writes on a currently read-only path.** Opening and sealing a week happens
  once per week per student, triggered lazily on the first request after the
  boundary passes. The overwhelming majority of requests remain pure reads;
  roughly one in a few dozen performs a small transaction.
- **A spike for returning students.** Someone away for ten weeks has ten weeks to
  seal in sequence on their first request back. This must be a bounded, efficient
  loop. If it cannot be made fast enough to sit on a request path, a scheduled
  job becomes mandatory rather than optional.
- **A one-time backfill.** Heavy while it runs, then never again.

### Net

Typical requests get faster — clearly so with the display fields carried in the
layout. Weekly boundary crossings get slightly slower. Storage grows by a
manageable amount. Nothing on the progress-write path changes.

---

## 12. Restrictions and risks

- **Working ahead stops helping the current week.** A student who watches week
  8's lectures while in week 5 gets no reduction in week 5's target. This is
  correct behaviour, but it will read as a bug unless the UI explains it.
- **Clearing catch-up early means idle time.** If the committed catch-up is
  finished on Tuesday, the remaining debt stays in later weeks and cannot be
  pulled forward without an explicit student action (see
  [open decision 2](#13-open-decisions)). The system must **never** pull it
  forward automatically — that automatic refill is the bug being fixed.
- **Closed rows are never revised.** If a lecture is un-marked or a duration is
  corrected after a week closed, the closed row is stale by design. Corrections
  flow into the live figures only.
- **Week boundaries become data-correctness-sensitive.** The boundary walk
  currently uses server local time, which is invisible while it only affects a
  calculation. Once crossing a boundary decides when a row is written, a single
  declared timezone per plan (or per platform) is required. The `timezone` column
  exists for this.
- **Read endpoints become read-then-conditionally-write,** inside a transaction.
- **The largest new table is around 5.2 million rows.** Not difficult for
  Postgres at this access pattern, but it is the figure to watch as active plans
  grow. See [7.3](#73-alternative-the-ideal-plan-as-a-json-column) for the escape
  hatch.
- **Every study-plan surface moves together.** The weekly hours block, the
  plan-by-week view, the dashboard hero card and the previous-week card all read
  the same builder. Good for consistency, but the blast radius of one behavioural
  change is every study-plan screen at once.
- **Existing tests encode the recompute-every-request behaviour.** Several
  assertions in the lecture service and study-plan utility specs become wrong by
  definition and need rewriting alongside the change.
- **A carried-forward lecture now appears twice in the same response** — once
  in its origin week, once at its destination. Clients that count rendered
  lectures rather than reading the `hours` block will double count.
  See [section 15](#15-carry-forward-visibility-at-the-origin-week).

---

## 13. Open decisions

**1. When a student edits their plan mid-week, when do the new hours take
effect?**

- *From the next week onward.* Week 5 stays exactly as it was — same lectures,
  same target — so nothing shifts under the student mid-week. Keeps every open
  week field write-once. Recommended.
- *Immediately.* The remaining days of the current week are re-planned, so the
  current week's `planned` figure changes mid-week. Closer to what most people
  expect from a settings change, but makes the open week row partly mutable.

**2. If a student clears their committed catch-up early, can they pull more
forward?**

- *No.* The week is complete; the remaining debt stays in later weeks. Safe
  default, and sufficient to fix the reported bug.
- *Yes, via an explicit action* — an "I have time, give me more" control that
  commits the next chunk of backlog into the current week. An addition on top of
  the fix, not part of it.

**3. Cascade behaviour on plan deletion.** Should week and revision history
survive a plan reset, or be wiped with it? Affects the `onDelete` clauses in
[6.6](#66-cascade-semantics).

**4. Should `startDate` edits be rejected or treated as a plan reset?** See
[6.1](#61-new-columns-on-usercoursestudyplan).

**5. Single change or phased?** See
[7.4](#74-other-options-considered) — phasing is possible but leaves a known
inconsistency in production between the two halves.

---

## 14. Code touchpoints

Line numbers are as of commit `6722ed9f` on `development` and will drift.

### Schema

| Location | What |
| --- | --- |
| `prisma/schema.prisma:1271` | `UserCourseStudyPlan` — the only persisted study-plan state today |

### The two bug sites

| Location | What |
| --- | --- |
| `src/lecture/study-plan.util.ts:563` | Weekly ledger — credits completion to the week that originally planned a lecture, so catch-up work never credits the week performing it |
| `src/lecture/study-plan.util.ts:714` | Carry-over distribution — re-pools every elapsed week's shortfall and re-pours it into the current week up to its capacity on every call |

### Pure schedule logic (no DB access, unit tested)

| Location | What |
| --- | --- |
| `src/lecture/study-plan.util.ts:145` | Builds the ideal weekly plan — becomes the source for the frozen layout |
| `src/lecture/study-plan.util.ts:300` | Per-day catch-up capacity (`min(quota × 1.5, cap)`, zero on rest days) |
| `src/lecture/study-plan.util.ts:450` | Backlog placement cascade — becomes the source for committed catch-up items |
| `src/lecture/study-plan.util.ts:664` | Per-week catch-up capacity |

### Service layer

| Location | What |
| --- | --- |
| `src/lecture/lecture.service.ts:3422-3444` | Tuning constants: buffer seconds, minimum split chunk, daily caps, catch-up multiplier |
| `src/lecture/lecture.service.ts:3575` | Plan create/update — needs the revision row, the `week1Start` freeze, and the partial layout rebuild |
| `src/lecture/lecture.service.ts:3666` | The deep content join — the dominant read cost, and the candidate for removal from the read path |
| `src/lecture/lecture.service.ts:3806` | Shared per-request context loader |
| `src/lecture/lecture.service.ts:3843` | The live forward walk (v1 endpoints) — separate builder, not affected by this change |
| `src/lecture/lecture.service.ts:4434` | The fixed-week builder — the main site of the change |
| `src/lecture/lecture.service.ts:4766` | Carry-over distribution wrapper |
| `src/lecture/lecture.service.ts:4793` | Ideal-plan wrapper — becomes a read of the frozen layout |
| `src/lecture/lecture.service.ts:4810` | Hour ledger wrapper |
| `src/lecture/lecture.service.ts:4828` | Per-week hours block shaping for the wire |
| `src/lecture/lecture.service.ts:5069` | Dashboard week overview |

### Affected endpoints

Reading the fixed-week builder, and therefore all affected:

- `GET /api/lecture/plan/weeks/v2`
- `GET /api/lecture/week-overview`
- `GET /api/lecture/progress-summary`

Reading the separate live forward walk, and therefore **not** affected:

- `GET /api/lecture/plan`
- `GET /api/lecture/plan/weeks`
- `GET /api/lecture/week`
- `GET /api/lecture/next`
- `POST /api/lecture/plan` — it returns the first generated week from
  `getFullScheduleByWeek` (v1), not the fixed-week builder. An earlier draft of
  this document listed it as affected; that was wrong.

Note that the two builders already disagree about what "this week" contains — the
forward walk re-places every unfinished lecture from today onward. This change
widens that gap, so it is worth deciding whether the v1 endpoints should
eventually be retired.

### Tests

| Location | What |
| --- | --- |
| `src/lecture/study-plan.util.spec.ts` | Unit tests for the pure logic above |
| `src/lecture/lecture.service.spec.ts` | Service-level tests, including carry-forward expectations that assume recompute-on-every-request |

---

## 15. Carry-forward visibility at the origin week

A separate requirement, raised after the rest of this document was written and
**implemented against the current unfrozen builder**. It is independent of the
freeze — it changes what is rendered, not what is computed — but the freeze
design has to preserve it, so it is recorded here.

### The requirement

When a lecture is carried forward, the week that originally planned it must
still show it, marked as having been carried forward, *and* the week it was
moved into must show it too. If week 1's content is carried into week 4, both
week 1 and week 4 report it.

### What was wrong before

`buildScheduleByWeekWithBacklog` split pending lectures into on-time and
backlog, and rendered only the on-time ones at their planned day. A backlog
lecture was therefore deleted from its origin week and existed only at its
cascade destination. The visible result: a week the student missed came back
with no lectures in it at all, while its `hours` block still reported the hours
it had planned — the week's own numbers disagreed with its own contents.

### What it does now

The origin week renders the backlog lecture from the frozen layout, alongside
the destination copy from the cascade:

| Side | Segment shown | Flags |
| --- | --- | --- |
| Origin week | the full segment the plan asked for | `isCarriedForward: true`, `carriedForwardToWeeks: number[]`, `isCarryOver: false` |
| Destination week | only the seconds still outstanding | `isCarryOver: true`, `carriedForwardFromWeek: number`, `isCarriedForward: false` |

Three details worth keeping in mind:

- **`carriedForwardToWeeks` is an array.** A lecture long enough to split can
  cascade into more than one week, and the cascade's segment boundaries are not
  the frozen layout's, so the origin-to-destination link is per-lecture, not
  per-segment.
- **The two copies are deliberately not identical.** The origin shows what was
  asked for; the destination shows what is left. For a half-watched lecture
  those are different second ranges on the same `videoId`.
- **`isCarryOver` was not reused for the origin side.** It means "debt cascaded
  *in* from an earlier week" and is what `progress-summary` filters the current
  week's chapter count on. Overloading it would have made origin copies count
  towards the current week's target.

### Why the hours are untouched

`computeWeeklyHourLedger` walks `original.originalDayItems` — the frozen layout
— not the rendered day map. An unwatched backlog lecture already counted against
its origin week's `planned`, and still does. `planned`, `carriedOver`, `target`
and `carryOverHours` are all byte-identical before and after this change. The
origin copy is the same debt made visible, not a second debt.

It also closes the inconsistency described above: an elapsed week's rendered
contents now match the hours it reports.

### Effect on the other endpoints

- **`GET /week-overview`** — `thisWeek`/`nextWeek` are unaffected, because an
  origin copy only ever exists in a week that has already ended.
  `previousWeek` is built by `buildPreviousWeekDays`, which already rendered
  origin-week lectures (as `late`); it now also receives the carry-forward map
  and carries `isCarriedForward` / `carriedForwardToWeeks`, so the card can say
  where the lecture went instead of only that it was missed. The two surfaces
  previously disagreed about a missed week's contents; they now agree.
- **`GET /progress-summary`** — unchanged output. Its chapter loop counts an
  item only when the lecture's original week *is* the current week, or when the
  item is flagged `isCarryOver` *in* the current week. An origin copy satisfies
  neither (its week has ended by definition), and `chapterVideos` is keyed by
  `videoId` in any case, so nothing double counts.
- **v1 endpoints** — unaffected; different builder, and it never removed a
  lecture from a week to begin with.

### What the freeze must preserve

Under the frozen model this falls out of the storage shape rather than needing
new columns: the `UserStudyPlanBaseline` row stays in the origin week and the
`UserStudyPlanCatchUpItem` row lands on the destination week.
`UserStudyPlanCatchUpItem.originWeekNumber` ([6.4](#64-userstudyplancatchupitem--the-committed-catch-up-lectures))
is already the destination-to-origin pointer, so `carriedForwardFromWeek` reads
straight off it. The origin-to-destination direction (`carriedForwardToWeeks`)
is a lookup of catch-up items by `videoId` for the plan — covered by the
existing `@@index([videoId])`, though a `(studyPlanWeekId, videoId)` access via
the week rows is the cheaper path in practice.

One behavioural difference to expect once the freeze lands: today the
destination is recomputed every request, so `carriedForwardToWeeks` can move
between requests. After the freeze it is a committed fact and stops moving —
which is the point of the freeze, and makes this requirement strictly more
useful.
