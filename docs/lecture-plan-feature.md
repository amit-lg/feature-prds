# Lecture Plan Feature

## Overview

A per-course study planner for students. When a student opens a course that has the study plan feature enabled, they fill a one-time form specifying how many hours they can study each day of the week, how many buffer days they want, and their start date. The system then computes a day-by-day lecture schedule on the fly whenever the student requests their next lecture or weekly plan.

No plan rows are stored in the database — the schedule is always calculated at request time from the student's settings and their existing progress data.

---

## Pre-conditions

Two things must be true before the form is shown to a student:

1. The course has `CourseOption` with `key = 'StudyPlan'` (value truthy) — some courses do not use this feature.
2. No `UserCourseStudyPlan` row exists for this `(userId, courseId)` pair — if one exists, the plan is already set up.

The `/check` endpoint handles both conditions and tells the frontend whether to show the setup form.

---

## Database Changes

### Only 1 new table: `UserCourseStudyPlan`

| Field | Type | Notes |
|---|---|---|
| `id` | Int (PK) | |
| `userId` | Int | FK → User |
| `courseId` | Int | FK → Course |
| `dailyHours` | Json | Hours available per day of the week (see shape below) |
| `bufferDays` | Int | Extra buffer days appended after all lectures are scheduled |
| `revisionDays` | Int | Days reserved for revision before the deadline (subtracted from effective deadline) |
| `examDate` | DateTime? | Student's target exam/deadline date (optional; overrides course/enrollment expiry) |
| `startDate` | DateTime | When the student begins their schedule |
| `isActive` | Boolean | False if student has regenerated/reset |
| `createdAt` | DateTime | |
| `updatedAt` | DateTime | |

**Unique constraint:** `(userId, courseId)` — one active plan per student per course.

#### `dailyHours` JSON shape

The field supports two formats interchangeably — the algorithm handles both.

**Simple format** (weekday/weekend grouping):
```json
{ "weekday": 8, "weekend": 12 }
```

**Day-specific format** (per-day hours):
```json
{
  "monday": 5,
  "tuesday": 3,
  "wednesday": 8,
  "thursday": 8,
  "friday": 6,
  "saturday": 12,
  "sunday": 0
}
```

A day with `0` hours (or a missing key) means no study that day — the algorithm skips it entirely.

**Lookup logic in the algorithm:**
```
hours = dailyHours[dayName]
     ?? dailyHours[isWeekend ? 'weekend' : 'weekday']
     ?? 0
```

Day-specific keys take priority; weekday/weekend acts as the fallback. This means both formats work without any code change — the frontend just decides which form to present to the student.

### No other new tables

Everything else is derived from existing tables:

| Data needed | Existing source |
|---|---|
| Lecture order | `LectureToCourse.order` |
| Lecture priority | `VideoInfo.importance` — only `required` is scheduled; `recommended` is surfaced as suggestions; `optional` is ignored |
| Lecture duration | `VideoInfo.duration` (seconds) |
| Completed | `UserToVideoInfo.done = true` |
| Skipped | `UserToVideoInfo.done = false` |
| Partially watched | `UserToVideoInfo.seen` (seconds watched) |
| Completed late | `UserToVideoInfo.done = true` + `updatedAt` vs computed scheduled date |

---

## Algorithm: Schedule Generation

### Constants (hardcoded)
```
MIN_DAILY_HOURS   = 0.5         // 30 minutes — system-wide floor
BUFFER_SECONDS    = 900         // 15 minutes — daily quota grace
MIN_SEGMENT_SECS  = 1800        // 30 minutes — minimum split chunk size
```

### Importance rules

| Importance | Behaviour |
|---|---|
| `required` | Included in the schedule, consumes daily quota, must be completed |
| `recommended` | Not scheduled, not counted against quota — surfaced as optional suggestions alongside today's required lectures |
| `optional` | Completely excluded from the plan and all responses |

### Input
- `UserCourseStudyPlan` settings for this student + course
- Only `required` lectures via `LectureToCourse → LectureToVideo → VideoInfo` where `importance = 'required'`
- All `UserToVideoInfo` rows for this student + course

### Step-by-step

**1. Fetch and order lectures**

Fetch only `VideoInfo` where `importance = 'required'`, ordered by `LectureToCourse.order` ASC.

`recommended` lectures are fetched separately and attached to the day response — they are never part of the scheduling loop.

**2. Filter out completed and skipped lectures**

- `UserToVideoInfo.done = true` → skip entirely (already done)
- `UserToVideoInfo.done = false` → skip entirely (student explicitly skipped)

**3. Adjust duration for partially watched lectures**

For lectures where a `UserToVideoInfo` row exists with `seen > 0` and `done` is null:
```
remainingDuration = video.duration - userToVideoInfo.seen
```
The algorithm schedules only the remaining portion.

**4. Walk days from `startDate`**

For each calendar day:
- Determine quota: `dailyHours[dayOfWeek] × 3600 + BUFFER_SECONDS` (e.g. `dailyHours['monday'] × 3600 + 900`)
- If `dailyHours[dayOfWeek] === 0` → skip this day entirely (rest day)
- Track `remainingSeconds` for the day
- Pick lectures from the ordered list and fill the day:

```
for each lecture:
  effectiveDuration = full duration OR remaining if partially watched

  if effectiveDuration <= remainingSeconds:
    → schedule full lecture today
    → deduct from remainingSeconds
    → move to next lecture

  else if remainingSeconds >= MIN_SEGMENT_SECS:
    → schedule a split: today covers (seenSoFar) to (seenSoFar + remainingSeconds)
    → move to next day with leftover duration
    → continue splitting across subsequent days if needed

  else (remainingSeconds < MIN_SEGMENT_SECS):
    → move to next day, do not start lecture today
```

**5. Buffer days**

After the last lecture is scheduled, append `bufferDays` empty calendar days. These are not returned as plan items — they represent the student's deadline cushion.

**6. Return the schedule**

The output is a list of day-grouped items. Each day has `required` scheduled lectures and a separate `recommended` list (lectures that fall on that date by course order, not consuming any quota):
```
[
  {
    date: "2026-06-18",
    items: [
      { videoId, lectureName, subject, subjects, fallNumber, startSecond, endSecond, segmentIndex, totalSegments, status }
    ],
    recommended: [
      { videoId, lectureName, duration }
    ]
  }
]
```

`subjects` is the full `CourseSubject` ancestry for the video's `FallNumber`, resolved via `FallNumberToSubject → CourseSubject` (self-referential up to 4 levels, e.g. Subject → Chapter → LOS → ...). Returned root-first as `{ id, name, type, order, otherJson }[]` — `[]` if the video has no `FallNumber` or subject link. `order` is each node's own `CourseSubject.order` (its position among its siblings), included on every level of the chain — use it to sort a subject's chapters, a chapter's LOS entries, etc. `otherJson` is each node's own `CourseSubject.otherJson` — an open-ended metadata bag (e.g. `{ length, numericalOrNot, difficulty, confusing, implevel, practice }` for topics imported via `POST /lecture/chapter/extra`), `null` if not set. `subject` is just the name of the deepest (most specific) entry in `subjects`, for callers that only want a flat label — `null` if `subjects` is empty. `fallNumber` is the `FallNumber.number` linked to the video via `FallNumberToVideoInfo` (`null` if none).

Both `subjects` and the lecture list itself are scoped to the course's actual content owner, not necessarily the course the student is enrolled in directly: if the course has a `CourseOption` with `key = 'templateCourseId'`, lectures and subjects are looked up under that template course instead (the same indirection used by `findAll`/`findLecture`), since content is often shared across several enrolled/child courses via one template.

---

## Status Calculation

Status is computed per lecture item, not stored, against a **baseline due date** — not the live schedule's `scheduledDate`. This distinction matters: the live forward walk that actually places pending items always starts at `max(startDate, today)`, so its own `scheduledDate` can never be in the past and can't tell "overdue" apart from "on track" by itself. The baseline is a separate, lightweight walk (`computeBaselineDueDates`) over every `required` video using its **full** duration (ignoring current progress), starting from the plan's original, un-clamped `startDate` — it answers "what day would this lecture finish if the student had followed the plan exactly from day one?" That day is each video's due date.

| Condition | Status |
|---|---|
| `UserToVideoInfo` row does not exist or `done = null`, due date is today or later | `pending` |
| `UserToVideoInfo.done = null`, due date has already passed | `late` |
| `UserToVideoInfo.done = true`, `updatedAt` at or before the due date's end of day | `done` |
| `UserToVideoInfo.done = true`, `updatedAt` after the due date's end of day | `done_late` |
| `UserToVideoInfo.done = false` | `skipped` |

The due date is per **video**, not per segment — a split lecture's due date is when its *last* segment would finish under the baseline walk, and every segment of that video shares the same due date for `late` purposes.

### Completed/skipped lectures reappear on the day they were finished

`buildSchedule` excludes done/skipped videos from the live forward walk (they don't need to be scheduled anymore), but it merges them back into the day list afterward, placed on the calendar day of their `UserToVideoInfo.updatedAt` — not left out of the response entirely. This is what makes a lecture a student just finished show up as `done` in `/week` immediately, and what lets `/plan` show past days with completed lectures instead of those days vanishing (previously, a done/skipped video was dropped from `videoQueue` before the day-walk began and never received a `scheduledDate` at all, so it could never appear in any response — `/week`, `/plan`, and `/plan/weeks` all shared this gap, and every item that did appear was always `pending`, since neither `late` nor `done`/`done_late`/`skipped` could ever actually be reached by the code).

A merged-in item uses `startSecond: 0`, `endSecond: <full duration>`, `segmentIndex: 1`, `totalSegments: 1`, and an empty `recommended: []` for any day it creates — there's no way to reconstruct which of a split video's individual daily chunks were watched on which day after the fact (only the final `seen`/`done`/`updatedAt` state is persisted), so a finished lecture is shown as one consolidated entry on its completion date rather than replaying its original per-day split.

This does **not** cover lectures a student is mid-way through (`done = null`, `seen > 0`) for a *past* date — those stay in the live forward walk and get rescheduled starting from today (see below), so they show up in the future, not on the day they were partially watched. `/week-overview`'s `previousWeek` is the endpoint for "what was I partway through last week" — it's reconstructed independently from raw activity rather than from `buildSchedule`'s output.

---

## Falling Behind: Automatic Recalculation

The plan is recalculated fresh on every API call, so there is no separate "recalculate" step.

When a student misses a lecture:
- The algorithm runs from `startDate` as usual
- Completed/skipped lectures are excluded from scheduling and merged back in on their completion date, marked `done`/`done_late`/`skipped` (see above)
- Missed lectures (`done = null`, due date already passed) are marked `late` and rescheduled starting from today
- The new schedule naturally pushes everything forward
- If remaining lectures no longer fit within the original buffer window, the projected end date extends — this is surfaced to the frontend

The student does not need to do anything. The plan self-corrects every time they load it.

---

## API Endpoints

All endpoints require `AuthGuard` (student JWT). None of them take a `:courseId` route param — the course is resolved server-side from the `watching_course_${userId}_${platformId}` cache key (set when the student opens/starts watching a course), the same mechanism `getResources`, `findAll`, and `findLecture` already use elsewhere in this module. If nothing is cached for that user+platform, every endpoint below throws `400 Bad Request` with `"You are not watching any course"` instead of accepting an explicit course id.

### `GET /lecture/check`
Returns whether the student needs to set up a plan.

**Response:**
```json
{
  "required": true,
  "reason": "no_plan"
}
```
`reason` can be: `no_plan` (form not filled), `feature_disabled` (CourseOption not set), `plan_exists` (already set up).

---

### `POST /lecture/plan`
Creates `UserCourseStudyPlan` if it doesn't exist, updates it if it does (upsert). Returns the first week of the generated schedule.

**Body (simple format):**
```json
{
  "dailyHours": { "weekday": 8, "weekend": 12 },
  "bufferDays": 5,
  "revisionDays": 14,
  "examDate": "2026-09-15",
  "startDate": "2026-06-18"
}
```

**Body (day-specific format):**
```json
{
  "dailyHours": { "monday": 5, "tuesday": 3, "wednesday": 8, "thursday": 8, "friday": 6, "saturday": 12, "sunday": 0 },
  "bufferDays": 5,
  "revisionDays": 14,
  "examDate": "2026-09-15",
  "startDate": "2026-06-18"
}
```

**Field notes:**
- `revisionDays` and `examDate` are optional (default `0` / `null`)
- If `examDate` is omitted, the deadline falls back to `UserToCourse.expiry`, then `Course.expiry`
- `revisionDays` are subtracted from the deadline: the algorithm warns if lectures won't finish before `examDate - revisionDays`

**Validation:**
- `dailyHours`: must contain either `weekday`/`weekend` keys, or all 7 day keys (`monday`–`sunday`), or a mix
- Each value: min `0` (rest day), max `24`
- At least one day must have hours > 0
- Each non-zero value must be ≥ `MIN_DAILY_HOURS` (0.5)
- `bufferDays`: min 0, max 60
- `revisionDays`: min 0, max 90
- `startDate`: today or future
- The plan must be able to finish the course in time — see below

#### Can the course be finished in time?

The last rule is the only one that reads the course rather than the payload, so it runs after all the others have passed. A plan whose hours cannot get through the content is **rejected, not saved** — the student finds out while the form is still open, instead of saving a plan and reading `isOverDeadline: true` back off the next screen.

The window measured runs from `startDate` to `examDate - revisionDays - bufferDays`. That end date is deliberately the one `projectedEndDate` is compared against in every schedule endpoint, so a plan accepted here cannot come straight back as over its own deadline. `examDate` resolves through the usual chain (`examDate` → `UserToCourse.expiry` → `Course.expiry`); with none of the three set there is no deadline to be late for and the rule is skipped entirely.

The comparison is hours-vs-hours, not a placement walk: it asks whether the pledged hours add up to the content still left, taking `seen` off each video's duration and ignoring anything already `done`/skipped. So a student half way through a course is judged on the work still to do, and editing a plan after finishing the course is never blocked. Lecture lumpiness (a 2h lecture on a day with 15 min of room) can only ever cost more time, never less — so a plan this **accepts** may still land a day or two late once whole lectures are placed, but one it **rejects** can never fit.

**400 body:**
```json
{
  "statusCode": 400,
  "error": "Bad Request",
  "message": "This course has about 180 hrs left, but your plan only gives you 120 hrs of study time before 2026-08-25 — you're 60 hrs short. Raise every study day to about 3 hrs, or push your exam date back.",
  "feasibility": {
    "feasible": false,
    "hasDeadline": true,
    "contentHours": 180,
    "totalContentHours": 360,
    "availableHours": 120,
    "shortfallHours": 60,
    "studyDays": 60,
    "requiredDailyHours": 3,
    "impossibleAtAnyHours": false,
    "lastStudyDate": "2026-08-25",
    "deadlineDate": "2026-09-15",
    "message": "This course has about 180 hrs left, but ..."
  }
}
```

`message` is written for the student and rendered verbatim, like every other rejection this endpoint raises. `feasibility` carries the same figures separately so the form can offer `requiredDailyHours` as a one-tap fix rather than parsing the sentence.

**There are two rejection sentences, because there are two different problems.**

*Fixable by studying more* (`impossibleAtAnyHours: false`) — quoted above. It names the shortfall and the per-day figure that would clear it, and its date is `lastStudyDate`, the end of the window that figure was divided over.

*Not fixable at any pledge* (`impossibleAtAnyHours: true`) — a shortfall the student cannot close by studying harder, so the sentence does not quote one. It names the size of the course, the study time the plan really leaves, and the date the student themselves entered:

```
This course is about 900 hrs long, but your plan only gives you 120 hrs of
study time before 2026-09-15. Even at 24 hrs a day you can't finish in time,
so push your exam date back or cut your revision and buffer days.
```

- The date is `deadlineDate` — the exam date, or the expiry standing in for it — **not** `lastStudyDate`. The student typed the exam date; `lastStudyDate` is that date with their revision and buffer days already taken off, which is a date they never entered and the very thing the sentence goes on to offer as a fix. The hours are still measured to `lastStudyDate`, since that is the time the plan really leaves for content.
- The hours figure depends on whether they are **creating** a plan or **editing** one. A first plan is quoted `totalContentHours` — the whole course, since none of it is behind them — and reads "is about X hrs long". An edit is quoted `contentHours`, what is left, and reads "has about X hrs left". Whether a plan exists is read **before** the upsert, or the answer would be "yes" every time.
- The **decision** never moves with the wording: it always runs on the remaining hours. Quoting the whole course to a student half way through would name a gap twice the real one, so the figure is a display choice only.

- `requiredDailyHours` is the figure needed on **every study day**, rounded up to the half hour the form steps in. Rest days stay rest days, so the denominator is `studyDays` — the days in the window pledging hours — not the days in the window. A weekday-only plan is never quoted a figure it could only reach by studying weekends.
- `requiredDailyHours` is `null` when the window holds no study day at all: the exam lands on or before the prep start once revision and buffer days come off it, or every day it covers is a rest day. The message names the ways out instead.
- `impossibleAtAnyHours` is `true` when the figure would exceed 24 — raising the daily hours cannot fix this plan, only a later exam date (or fewer revision/buffer days) can, and the message says so.

**Frontend:** `feasibility` is the one 400 worth more than a toast. Offer the fix rather than only reporting the problem: when `impossibleAtAnyHours` is `false`, a "Use {requiredDailyHours} hrs/day" action that writes the figure into every non-zero day and resubmits; when it is `true`, send them back to step 1 with the exam date focused.

---

### `GET /lecture/next`
Returns the next lecture the student should watch — the first `pending` or `late` item across the full schedule.

**Response:** same item shape as an entry in `/week`'s `days[].items[]`, plus `scheduledDate`.
```json
{
  "videoId": 5,
  "lectureName": "Introduction to Calculus",
  "subject": "Mathematics",
  "subjects": [
    { "id": 1, "name": "Mathematics", "type": "subject", "order": 1, "otherJson": null },
    { "id": 12, "name": "Calculus", "type": "chapter", "order": 2, "otherJson": { "length": "Long", "numericalOrNot": "Numerical", "difficulty": "Hard", "confusing": "Yes", "implevel": "High", "practice": "Extra" } },
    { "id": 145, "name": "Limits and Derivatives", "type": "los", "order": 1, "otherJson": null }
  ],
  "fallNumber": "2024",
  "startSecond": 0,
  "endSecond": 7200,
  "segmentIndex": 1,
  "totalSegments": 2,
  "status": "pending",
  "scheduledDate": "2026-06-18T00:00:00.000"
}
```

Returns `null` if all lectures are done or skipped.

---

### `/week` response shape (the `GET /lecture/week` route was removed in #479; this shape is still what `/plan` returns)
Describes the item shape for lectures scheduled for a week (today → Sunday), plus deadline metadata.

**Response:**
```json
{
  "days": [
    {
      "date": "2026-06-18",
      "items": [
        {
          "videoId": 5,
          "lectureName": "Introduction to Calculus",
          "subject": "Mathematics",
          "subjects": [
            { "id": 1, "name": "Mathematics", "type": "subject", "order": 1, "otherJson": null },
            { "id": 12, "name": "Calculus", "type": "chapter", "order": 2, "otherJson": { "length": "Long", "numericalOrNot": "Numerical", "difficulty": "Hard", "confusing": "Yes", "implevel": "High", "practice": "Extra" } },
            { "id": 145, "name": "Limits and Derivatives", "type": "los", "order": 1, "otherJson": null }
          ],
          "fallNumber": "2024",
          "startSecond": 0,
          "endSecond": 7200,
          "segmentIndex": 1,
          "totalSegments": 2,
          "status": "pending"
        }
      ],
      "recommended": []
    }
  ],
  "examDate": "2026-09-15",
  "revisionDays": 14,
  "deadline": "2026-09-01",
  "projectedEndDate": "2026-08-20",
  "isOverDeadline": false
}
```

`deadline` = `examDate - revisionDays` (the date by which all lectures must be finished). `null` if no exam date or course expiry exists.

`projectedEndDate` = the date of the last day in `days[]`. If every required lecture is already done or skipped, this is the date the last one was actually finished, not `null` — a student who finished everything very late will correctly show `isOverDeadline: true` rather than the deadline check being skipped.

`isOverDeadline` = `true` if the student's projected finish date is after the deadline — show a warning banner.

---

### `GET /lecture/plan`
Returns the full schedule, grouped by date — every upcoming pending/late day, plus every past day that has a completed or skipped lecture on it. Same shape as `/week` but not limited to the current week.

**Response shape:** identical to `/week` — `{ days, examDate, revisionDays, deadline, projectedEndDate, isOverDeadline }`.

---

Updating the plan (student changes their hours) uses the same `POST /lecture/plan` endpoint — it upserts the record. Progress (`UserToVideoInfo`) is always preserved regardless of plan changes.

---

### `GET /lecture/plan/settings`
The values the student themselves saved on the setup form, read straight off `UserCourseStudyPlan`, so the form can prefill when they come back to edit their plan instead of reopening on defaults and silently overwriting their settings.

**Response — plan exists:**
```json
{
  "hasPlan": true,
  "settings": {
    "dailyHours": { "weekday": 2, "weekend": 4 },
    "bufferDays": 3,
    "revisionDays": 7,
    "examDate": "2026-09-15",
    "startDate": "2026-06-18",
    "isActive": true,
    "updatedAt": "2026-08-01T10:22:03.000Z"
  }
}
```

**Response — no plan, or StudyPlan not enabled for the course:**
```json
{ "hasPlan": false, "settings": null }
```

Both are `200`. A first-time student opening the form is the normal path, not a failure, so this route does not raise the `400 No study plan found for this course` the schedule endpoints do.

**`examDate` here is NOT the `examDate` the other plan endpoints return.** `/plan`, `/plan/weeks`, `/plan/weeks/v2`, `/week` and `/progress-summary` all report the RESOLVED deadline — `plan.examDate → UserToCourse.expiry → Course.expiry` — so a student who set no exam date gets a course expiry back from them. Prefilling a form from that value and POSTing it would persist the expiry as the student's own exam date. This route returns the stored column: `null` when they set none. Prefill from here only.

`dailyHours` comes back in whatever shape it was saved in — the simple `{ weekday, weekend }` form or the per-day `{ monday … sunday }` form, unnormalised — so the caller can tell which editing mode to restore.

`bufferDays`, `revisionDays` and `startDate` are as stored. Dates are `YYYY-MM-DD`, matching what `POST /lecture/plan` accepts, so the values round-trip.

---

### `GET /lecture/plan/weeks`
Returns the full upcoming schedule grouped into calendar weeks (Sunday → Saturday) — for a "full study plan" screen where the student scrolls week by week instead of day by day.

Only days that have scheduled items appear (same as `/plan`); rest days and days with nothing left to watch are absent. `weekNumber` is sequential (1, 2, 3, …) in chronological order — it does not correspond to the calendar week-of-year.

**Response:**
```json
{
  "weeks": [
    {
      "weekNumber": 1,
      "weekStart": "2026-06-14",
      "weekEnd": "2026-06-20",
      "days": [
        {
          "date": "2026-06-18",
          "items": [
            {
              "videoId": 5,
              "lectureName": "Introduction to Calculus",
              "subject": "Mathematics",
              "fallNumber": "2024",
              "startSecond": 0,
              "endSecond": 7200,
              "segmentIndex": 1,
              "totalSegments": 2,
              "status": "pending"
            }
          ],
          "recommended": []
        }
      ]
    },
    {
      "weekNumber": 2,
      "weekStart": "2026-06-21",
      "weekEnd": "2026-06-27",
      "days": [ ]
    }
  ],
  "examDate": "2026-09-15",
  "revisionDays": 14,
  "deadline": "2026-09-01",
  "projectedEndDate": "2026-08-20",
  "isOverDeadline": false
}
```

| Field | Description |
|-------|-------------|
| `weekNumber` | 1-indexed, in chronological order |
| `weekStart` / `weekEnd` | The Sunday–Saturday span this group covers |
| `days` | Same shape as `/week`'s `days[]` — can be empty if the week is entirely rest days |

#### `GET /lecture/plan/weeks/v2`

The fixed-week variant: each day is reshaped into a subject → chapter → LOS tree, weeks are the plan's own frozen Sunday–Saturday grid, and a lecture that missed its week is cascaded forward and flagged `isCarryOver: true`.

It also carries the same carry-over reporting as `/lecture/week-overview` — `weeks[].hours` per week, plus top-level `carryOverHours` and `cannotCompleteInTime`. Both endpoints compute it once from the same schedule, so a given week's figures are identical whichever one you read. See [the `hours` ledger](#the-hours-ledger--carry-over) for the arithmetic.

---

### `GET /lecture/week-overview`
Returns the previous, current, and next calendar week (Sunday–Saturday) in one call — for a dashboard section that shows all three side by side.

`thisWeek`/`nextWeek` are sliced from the same **fixed-week** schedule as `/plan/weeks/v2` — not the live forward walk behind `/week` and `/plan/weeks`. The forward walk re-places every unfinished lecture from today onward, which collapses "this week" into whatever happens to fit and leaves no stable weekly target for hours to carry into; it also disagreed with `/plan/weeks/v2` and `/progress-summary`, so the dashboard could show two different versions of the same week.

`previousWeek` is **not** a slice of that schedule either — the backlog cascade moves a missed lecture *forward*, out of the week it was missed in. It is reconstructed from two sources instead:

1. **The frozen original weekly plan** — the same full-duration, fixed week assignment `/plan/weeks/v2` and `/progress-summary` use. This is "what that week was supposed to cover", and it exists whether or not the student did any of it. Each planned segment is returned on its planned day, carrying the student's current progress state.
2. **Raw activity in that week** — `UserToVideoInfo` rows whose `updatedAt` falls inside the week, for videos the week never planned: a `recommended`/`optional` lecture the student watched, or a required one belonging to another week. These are placed on the day the row was last written, since that's the only date evidence they have.

The two are merged and deduped by video (a planned video is never also emitted from the activity pass).

**Why not activity alone.** `previousWeek` used to be built purely from the `updatedAt` window, which made a missed week render as **nothing at all**. `updatedAt` is "row last written", not "watched on" — a progress heartbeat, a done flip, or a self-study checklist save all move it. A student who did *not* finish last week keeps opening those same lectures this week, dragging every one of their rows' `updatedAt` into the current week, so the previous-week window matched zero rows. A cleanly finished week (rows never touched again) survived, so the card failed exactly when the week went badly. Anchoring on the frozen plan removes that dependency: partial work always shows, and a lecture that was planned and never touched is reported rather than omitted.

**Response:**
```json
{
  "previousWeek": {
    "weekStart": "2026-06-07",
    "weekEnd": "2026-06-13",
    "days": [
      {
        "date": "2026-06-09",
        "items": [
          {
            "videoId": 4,
            "lectureName": "Functions and Limits",
            "subject": "Mathematics",
            "subjects": [
              { "id": 1, "name": "Mathematics", "type": "subject", "order": 1, "otherJson": null }
            ],
            "fallNumber": "2024",
            "duration": 5400,
            "seen": 5400,
            "startSecond": 0,
            "endSecond": 5400,
            "segmentIndex": 1,
            "totalSegments": 1,
            "status": "done",
            "updatedAt": "2026-06-09T14:02:11.000Z"
          }
        ]
      }
    ],
    "hours": {
      "planned": 32,
      "carriedOver": 0,
      "target": 32,
      "completed": 30,
      "skipped": 0,
      "remaining": 2
    }
  },
  "thisWeek": {
    "weekStart": "2026-06-14",
    "weekEnd": "2026-06-20",
    "days": [ ],
    "hours": {
      "planned": 32,
      "carriedOver": 2,
      "target": 34,
      "completed": 0,
      "skipped": 0,
      "remaining": 34
    }
  },
  "nextWeek": {
    "weekStart": "2026-06-21",
    "weekEnd": "2026-06-27",
    "days": [ ],
    "hours": {
      "planned": 32,
      "carriedOver": 34,
      "target": 66,
      "completed": 0,
      "skipped": 0,
      "remaining": 66
    }
  },
  "carryOverHours": 2,
  "cannotCompleteInTime": false,
  "examDate": "2026-09-15",
  "revisionDays": 14,
  "deadline": "2026-09-01",
  "projectedEndDate": "2026-08-20",
  "isOverDeadline": false
}
```

| Field | Description |
|---|---|
| `previousWeek.days[].items[].status` | `done`, `skipped`, `in_progress` (partial `seen`, not yet marked done), or `late` (planned that week, never touched) |
| `previousWeek.days[].items[]` | Also carries `startSecond`/`endSecond`/`segmentIndex`/`totalSegments` — the planned segment bounds for that day, so a day's hours are `endSecond - startSecond` summed, same as `/week`. Activity on an unplanned video reports the full video as one segment |
| `thisWeek.days` | The **whole** Sunday–Saturday week, including days already elapsed — the fixed-week schedule computes past dates, which the old forward walk could not |
| `nextWeek.days` | Same shape, for the calendar week following `thisWeek` |
| `<week>.hours` | The carry-over ledger for that week, in hours (1 decimal). See below |
| `days[].items[].isCarryOver` | `true` when this segment was cascaded in from an earlier week — the flag to highlight on. Present on `/plan/weeks/v2`'s nested lectures too |
| `carryOverHours` | The outstanding backlog across the whole plan. A week's `hours.carriedOver` is only that week's equal share of it, so this is the total |
| `cannotCompleteInTime` | `true` when some remaining week is asked for more than `12h × studyDays` — the student cannot finish the course in the stipulated time even studying 12 hrs a day |

`previousWeek.days` omits any date that had neither planned content nor activity — a previous week that was entirely rest days *and* saw no work returns `days: []`. A week that had planned lectures always returns them, whatever the student did or didn't do.

#### The `hours` ledger — carry-over

Every week block carries the same object, in hours rounded to one decimal:

| Field | Meaning |
|---|---|
| `planned` | The frozen plan's own hours for that week |
| `carriedOver` | This week's share of the backlog — the pool split **equally** across every remaining week |
| `target` | `planned + carriedOver` — what the student actually owes that week |
| `completed` | Hours of *that week's own* planned content already watched |
| `skipped` | Hours of that week's content explicitly skipped |
| `remaining` | `max(0, target − completed − skipped)` |

`planned` and `carriedOver` are deliberately reported separately rather than pre-summed, so the UI can render the target as **"32 hrs + 2 hrs"** and highlight the 2 hrs as catch-up:

```
This Week (Jun 14 – Jun 20)          32 hrs  + 2 hrs catch-up
```

**The backlog is pooled, then split equally.** Every week that has already ended contributes its own shortfall to one pool, and every week the student has left owes the **same share** of it:

```
shortfall(w)   = max(0, planned(w) − completed(w) − skipped(w))
pool           = Σ shortfall(w)     for every elapsed week w
carriedOver(w) = pool / remainingWeeks
target(w)      = planned(w) + carriedOver(w)
ceiling(w)     = 12h × studyDays(w)
```

40 hrs behind with ten weeks left is 4 hrs of catch-up a week for ten weeks — not a punishing 24 hrs next week and nothing after it. The **current week counts as a whole week** and takes a whole share even when today is Wednesday: a plain equal split, not one prorated by the days it has left.

The share is **not capped** at what the week can hold. Capping it hid the problem — the excess quietly moved to later weeks and every week reported a comfortable target, so nothing said the plan had become impossible. A week whose ask exceeds its ceiling now sets `cannotCompleteInTime` instead.

**The ceiling is 12 hrs per study day.** That is the most a student can be asked to study in a day, so a full seven-day week holds `12 × 7` = **84 hrs**, plan and catch-up together. A **rest day** (0 hrs pledged) holds nothing, so a Mon–Fri student's week holds `12 × 5` = **60 hrs**, not 84 — it is the one day the student said they cannot study, and counting it would promise hours no lecture can ever be placed in. For the **week in progress** the ceiling covers only the days it has left: by Wednesday it is `12 × 4`.

> The ceiling used to be `min(pledge × 1.5, 12h)` per day. That capped a 3 hrs/day student's catch-up at 4.5 hrs a day and reported `cannotCompleteInTime` for a backlog that fits inside 12 hrs days easily. The pledge governs what the **plan books**; the 12 hrs/day ceiling governs what **catch-up may add** on top of it.

Worked example — `{weekday: 8, weekend: 10}` is `(8 × 5) + (10 × 2)` = **60 hrs a week**. On a 24-week course with weeks 1–4 missed entirely and today in week 5 (a Wednesday):

```
pool        = 4 × 60                    = 240 hrs
remaining   = weeks 5..24               =  20 weeks
carry each  = 240 / 20                  =  12 hrs a week
week 5      = 60 planned + 12 carry     =  72 hrs
week 6      = 60 planned + 12 carry     =  72 hrs
…and so on through week 24
```

Week 5's ceiling is only `12 × 4` = 48 hrs (Wed–Sat), against the 34 hrs of its own content still ahead plus its 12 hr share = 46 hrs — it fits. Had it not, `cannotCompleteInTime` would be `true`.

Elapsed weeks get `carriedOver: 0` — there is no point assigning catch-up to a day that has gone; their `remaining` is their own shortfall, which is what feeds the pool.

Pooling from each week's *own* content is what makes this stable: an unwatched lecture keeps counting against the week that planned it, so recomputing never double counts what an earlier run already handed out, and watching it later simply shrinks the pool. Nothing is persisted — the whole ledger is recomputed on every request.

**The window is the plan's duration, not the lecture horizon.** The remaining weeks run from the current week through the week containing the plan's `deadline` (`examDate − revisionDays`, falling back to enrollment/course expiry; with no deadline at all, the last week that holds lectures). Weeks past the last lecture plan nothing and so offer their whole ceiling — 28 hrs of backlog against an exam a year out is absorbed without trouble, and must never be reported as impossible.

**When the backlog stops fitting.** Top-level `cannotCompleteInTime` is `true` when some week the student still has to live through is asked for more than it can physically hold:

```
owed(w) = plannedStillAhead(w) + carriedOver(w)
flag    = ∃ w ≥ currentWeek : owed(w) > 12h × studyDays(w)
```

Either the equal share of the backlog is that large, or the plan's own content for that week already is — a week booking more than 84 hrs is impossible however it is arranged. It is also `true` when the deadline has already passed and there is no week left to ask. `carryOverHours` still reports the real uncapped backlog, so the UI can state the true figure.

Two consequences worth knowing:

- Because the split is equal and uncapped, the flag can fire while the window *as a whole* still has room — a backlog that fits only if the later, emptier weeks take more than their share is reported rather than silently re-balanced. That is the trade-off of a plain equal split.
- The pledge no longer gates the flag. A 3 hrs/day student who falls 30 hrs behind with four weeks left is fine (7.5 hrs of catch-up a week against a 12 hrs/day ceiling), where the old `pledge × 1.5` rule called it impossible.

This is distinct from `isOverDeadline`, which compares the projected finish date against the exam/expiry date. `cannotCompleteInTime` asks whether any remaining week is being asked for more than 12 hrs a day; both can be true independently.

Skipped time never carries. The student declined that lecture, so it is not a debt; it is also not study time, which is why it is subtracted separately instead of being folded into `completed`.

Past the plan's own horizon, `planned` is `0` but whatever was still unmet keeps being reported as `carriedOver`/`target` — a finished plan with unwatched lectures does not silently zero out.

> **Shared by three endpoints.** `/lecture/week-overview`, `/lecture/plan/weeks/v2` and `/lecture/progress-summary` all run the same distribution over the same schedule, so `carriedOver` / `target` / `carryOverHours` / `cannotCompleteInTime` mean exactly the same thing in each. They differ only in scope — three weeks, every week, or just the current one. A given week's figures are identical whichever endpoint you read them from.
>
> `/progress-summary`'s `weeklyTarget` follows `target` rather than `planned`: `total` is every chapter owed this week — the ones the plan assigns to it **plus** any carried forward — and `carriedOver` says how many of that total are catch-up, so `total − carriedOver` is the week's own count. 8 own chapters with 2 outstanding from last week reads as `total: 10, carriedOver: 2`, the chapter-count equivalent of "18h + 9h". A carried chapter keeps being asked for until it is actually finished, so `achieved < total` while a backlog remains is the honest signal, not a bug.
>
> On `/progress-summary` the ledger arrives as `weeklyHours` (`planned`, `completed`, `carriedOver`, `target`, `remaining`) plus top-level `carryOverHours` and `cannotCompleteInTime`. `planned` deliberately stays the week's *own* hours so the familiar "completed / planned" reading is unchanged; the catch-up is the separate `carriedOver` figure. It used to be recomputed there by summing the segments that happened to sit in the week, which blended plan and catch-up into one number.

#### How the carried-over lectures themselves are placed

The ledger says how many hours are owed; the backlog cascade decides which day each overdue lecture actually lands on. It walks forward in course order, filling only capacity the frozen plan has not already used, and the placed segments are flagged `isCarryOver: true`.

Its capacity rules:

- **Every remaining week takes an equal slice** (`backlog / weeksLeft`), spread over that week's own study days. This is the same split the ledger reports, over the same window, so a week's catch-up hours and the catch-up lectures rendered in it agree to within a lecture.
- **The slice is placed whatever room the week has left.** A week whose days are already at 12h is loaded past 12h rather than passing the excess to a later week — otherwise the equal split silently becomes "fill each week to its ceiling and dump the rest", which is what produced weeks of `13.9h / 52.5h / 52.2h / 151.1h` with 109h of it on a single date. An overloaded week is reported by `cannotCompleteInTime`, not smoothed away. On a backlog that *does* fit, the slice is by construction small enough to keep every day inside its 12h.
- **A rest day (0 hours declared) never receives catch-up.** It is the one day the student explicitly said they cannot study.
- **The window is the plan's own last allowed day** (`deadline − bufferDays`) — the same day the plan paces itself to, so catch-up never lands past the exam either, and the walk reaches it even when the last lecture is weeks earlier.
- With **no deadline** there is no window to size a slice from, and the cascade falls back to catching up as early as it can (greedy: fill each day to 12h from today onwards).
- **Nothing is ever placed before today.** Catch-up on an elapsed day is work the student can no longer do, and it consumed capacity that no longer exists.
- **The horizon always reaches the end of next calendar week.** A plan whose own horizon has already passed still schedules its catch-up onto days the student can act on, instead of piling everything onto the final planned date.
- Anything that still doesn't fit lands on the horizon's last day. With an equal spread this is now only a guard — the slices add up to the whole backlog and each is placed regardless of room — so it fires only in degenerate cases (a window of nothing but rest days).

> A week entered near its end still takes a **whole** share, so a current week with two days left carries that share on those two days. Prorating it by days left is a one-line change if that reads worse in the UI than the honest overload.

**The slice floor is 5 minutes** (`MIN_SEGMENT_SECS`). A lecture is cut no finer than that when it will not fit the room a day has left, which is what lets a carried lecture straddle a week boundary. At the old 30 minutes it could not, so a plan whose weekly catch-up share was about one lecture long — a small backlog spread over a year, ~42 min a week — placed two lectures in one week and none in the next; a real response had 7 empty weeks out of 48. Costs of the finer floor: roughly 3× as many segments (a lecture can appear in up to ~6 pieces), and because per-week hours are rounded to one decimal, almost every week now carries a sliver that rounds up — so the *displayed* `carriedOver` figures sum to slightly more than `carryOverHours` (2.2 against 2.0 in one test). The placements themselves still total the backlog exactly.

A lecture that was planned last week and is still unfinished appears in both `previousWeek` (as `late`, on its planned day) and in `thisWeek`/`nextWeek` (rescheduled forward) — the first is history, the second is the catch-up.

`weekStart`/`weekEnd` on all three weeks are local calendar dates (`TZ`), matching the day keys inside them.

---

### `GET /lecture/subject-progress`
Returns lecture completion rolled up by subject, nested to match the `CourseSubject` hierarchy (subject → chapter → LOS → ...), with each level sorted by its own `order`. For a "progress by subject" screen (e.g. a syllabus tracker showing how far along the student is in each subject/chapter).

Only `required` lectures are counted — same set as the schedule algorithm ([Importance rules](#importance-rules)) — so these numbers always match what `/plan` and `/week` show.

**Response:**
```json
{
  "courseId": 12,
  "subjects": [
    {
      "id": 1,
      "name": "Mathematics",
      "type": "subject",
      "order": 1,
      "otherJson": null,
      "total": 20,
      "done": 12,
      "skipped": 1,
      "inProgress": 2,
      "notStarted": 5,
      "percentComplete": 60,
      "children": [
        {
          "id": 12,
          "name": "Calculus",
          "type": "chapter",
          "order": 2,
          "otherJson": { "length": "Long", "numericalOrNot": "Numerical", "difficulty": "Hard", "confusing": "Yes", "implevel": "High", "practice": "Extra" },
          "total": 10,
          "done": 5,
          "skipped": 0,
          "inProgress": 1,
          "notStarted": 4,
          "percentComplete": 50,
          "children": [
            {
              "id": 145,
              "name": "Limits and Derivatives",
              "type": "los",
              "order": 1,
              "otherJson": null,
              "total": 4,
              "done": 4,
              "skipped": 0,
              "inProgress": 0,
              "notStarted": 0,
              "percentComplete": 100,
              "children": []
            }
          ]
        }
      ]
    }
  ],
  "unassigned": {
    "total": 3,
    "done": 1,
    "skipped": 0,
    "inProgress": 0,
    "notStarted": 2,
    "percentComplete": 33
  }
}
```

| Field | Description |
|---|---|
| `subjects[]` | Root-level subjects (`type: "subject"`), each with `children[]` nested one level deeper per `CourseSubject` level (chapter, LOS, ...) |
| `order` | The node's own `CourseSubject.order` — siblings at every level are pre-sorted by this, so no client-side sorting needed |
| `otherJson` | The node's own `CourseSubject.otherJson` — an open-ended metadata bag (e.g. `{ length, numericalOrNot, difficulty, confusing, implevel, practice }` for topics imported via `POST /lecture/chapter/extra`), `null` if not set |
| `total` / `done` / `skipped` / `inProgress` / `notStarted` | Counts of `required` lectures under that node (and everything beneath it), by status. A node's `total` is the sum of its own directly-tagged lectures plus all descendants' |
| `percentComplete` | `done / total`, rounded to the nearest integer, `0` if `total` is `0` |
| `unassigned` | Rollup for `required` lectures whose video has no `FallNumber`/subject link at all — same shape as a subject node, minus `id`/`name`/`type`/`order`/`otherJson`/`children` |

Status per lecture is derived directly from `UserToVideoInfo`, same source as elsewhere: `done: true` → `done`, `done: false` → `skipped`, `done: null` with `seen > 0` → `inProgress`, otherwise → `notStarted`. This does not compute `late` (that requires the full day-walk schedule, which a per-subject rollup doesn't need).

---

### `GET /lecture/resume`
Returns the video the student was most recently watching in this course and has not yet finished, so the player can resume from where they left off.

Looks for `UserToVideoInfo` rows where `done = null` and `seen > 0`, picks the most recently updated one, and returns its resume position.

**Response:**
```json
{
  "videoId": 5,
  "seen": 1800,
  "lastSeen": 1823,
  "duration": 7200,
  "videoCode": "calc-01",
  "lecture": {
    "name": "Introduction to Calculus",
    "contentCovered": "Limits, derivatives"
  },
  "updatedAt": "2026-06-18T10:32:00.000Z"
}
```

| Field | Description |
|-------|-------------|
| `videoId` | The video to load in the player |
| `seen` | Total seconds watched so far |
| `lastSeen` | Exact playback position to seek to on resume |
| `duration` | Total video duration in seconds |
| `videoCode` | Video code for the player |
| `lecture` | Lecture name and content covered (`null` if no lecture link found) |
| `updatedAt` | When progress was last saved — shown as "last watched" timestamp |

Returns `null` if there is no in-progress video (all done, all skipped, or never started).

---

### `PATCH /lecture/progress`
Saves the student's current playback position. Call this periodically while the video is playing (every 10–15 seconds) and on pause/seek/close. This is what powers the resume feature.

**Body:**
```json
{
  "videoId": 5,
  "seen": 1800,
  "lastSeen": 1823
}
```

| Field | Description |
|-------|-------------|
| `videoId` | The video being watched |
| `seen` | Total seconds watched so far (used by the schedule algorithm for partial-watch detection) |
| `lastSeen` | Current playback position to resume from |

Creates the `UserToVideoInfo` row if it doesn't exist, updates `seen` and `lastSeen` if it does. Does not touch `done`.

**Response:** the updated (or created) `UserToVideoInfo` record.

---

## Split Lecture Example

Student: 2 hours/day. Lecture B: 3 hours.

| Day | startSecond | endSecond | segmentIndex | totalSegments |
|---|---|---|---|---|
| June 18 | 0 | 7200 | 1 | 3 |
| June 19 | 7200 | 14400 | 2 | 3 |
| June 20 | 14400 | 10800 | 3 | 3 |

The video player on the frontend uses `startSecond` to seek to the right position and `endSecond` to know when the day's segment is complete.

Segment is marked done when `UserToVideoInfo.seen >= endSecond`.

---

## Module Structure

No new module. All code goes into the existing lecture module:

```
src/lecture/
  lecture.controller.ts        ← add 8 new routes
  lecture.service.ts           ← add plan service methods
  dto/
    create-study-plan.dto.ts   ← new DTO
```

### `lecture.service.ts` — new methods added

All of the below (except `resolveWatchingCourseId` itself) take `platformId` where the table below says so, not `courseId` — each resolves the course id from the watching-course cache as its first step.

| Method | Purpose |
|---|---|
| `resolveWatchingCourseId(userId, platformId)` | Private helper — resolves `courseId` from the `watching_course` cache, `400` if nothing is cached |
| `checkStudyPlan(userId, platformId)` | Checks CourseOption + existing plan |
| `upsertStudyPlan(userId, platformId, dto)` | Saves UserCourseStudyPlan (upsert — creates or updates) |
| `getStudyPlanSettings(userId, platformId)` | Returns the UserCourseStudyPlan columns as stored, for prefilling the setup form. One row read, no schedule build |
| `buildSchedule(userId, courseId)` | Private — runs the algorithm, returns full schedule. Callers below all resolve `courseId` first, then call this |
| `getNextLecture(userId, platformId)` | Returns first pending/late item from schedule |
| `getWeekSchedule(userId, platformId)` | Returns this week's items |
| `getFullSchedule(userId, platformId)` | Returns the full schedule, flat |
| `getFullScheduleByWeek(userId, platformId)` | Returns the full schedule grouped into calendar weeks |
| `getWeekOverview(userId, platformId)` | Returns previous/this/next calendar week for the dashboard; previous week is built from raw activity, not the schedule |
| `getSubjectProgress(userId, platformId)` | Returns lecture completion rolled up by subject, nested and order-sorted |
| `getResumeVideo(userId, platformId)` | Returns the most recently in-progress video, if any |
| `updateProgress(userId, videoId, seen, lastSeen)` | Saves playback position — not course-scoped, `videoId` alone identifies the row |

---

## Edge Cases

| Case | Behaviour |
|---|---|
| Student has 0 lectures completed | Algorithm starts from lecture 1 |
| Student is mid-video (`seen > 0`, `done = null`) | Algorithm schedules only remaining seconds |
| All lectures done | `/next` returns null, `/week` returns empty |
| Lecture duration < MIN_SEGMENT_SECS (30 min) | Scheduled as-is, no minimum enforced on the lecture itself |
| Student has more hours than lectures | All lectures fit in fewer days; buffer days pad the end |
| New lecture added to course after plan created | Automatically appears in schedule on next API call since plan is computed live |
| Lecture removed from course after plan created | Automatically disappears from schedule on next API call |
| Student updates hours (`/regenerate`) | New plan recalculated from today; past done/skipped untouched |

---

## Frontend Instructions

### 1. On Course Open — Check if Plan Setup is Required

When the student opens a course, call:
```
GET /lecture/check
```

**If `required: true` and `reason: 'no_plan'`** → block the course view and show the study plan setup form.

**If `required: false` or `reason: 'feature_disabled'`** → skip the form entirely, proceed to course view normally.

**If `reason: 'plan_exists'`** → plan already set up, proceed normally.

---

### 2. Study Plan Setup Form

Show this form when `reason: 'no_plan'`. The same form is reused when the student wants to update their hours later (same API, upsert).

**Fields to collect:**

| Field | Input Type | Notes |
|---|---|---|
| Study hours | Toggle + number inputs | Default: simple weekday/weekend toggle. Advanced mode: per-day inputs (Mon–Sun) |
| Buffer days | Number input | How many padding days at end of plan. Min 0, max 60 |
| Exam / target date | Date picker (optional) | The student's exam date. If blank, falls back to course access expiry |
| Revision days | Number input (optional) | Days reserved for revision before the exam. Default 0, max 90 |
| Start date | Date picker | Defaults to today, cannot be in the past |

**Simple mode UI (default):**
```
Weekday hours:  [8] hrs/day
Weekend hours:  [12] hrs/day

Exam date (optional):  [ Jun 18 2026 ]
Revision days:         [ 14 ]
Start date:            [ Jun 18 2026 ]
Buffer days:           [ 5 ]
```

**Advanced mode UI (opt-in toggle "Set per day"):**
```
Mon [5]  Tue [3]  Wed [8]  Thu [8]  Fri [6]  Sat [12]  Sun [0]
```
A day set to `0` = rest day (no lectures that day).

**On submit:** `POST /lecture/plan`

Send `dailyHours` as `{ "weekday": 8, "weekend": 12 }` for simple mode, or `{ "monday": 5, "tuesday": 3, ... }` for advanced mode. Include `examDate` and `revisionDays` only if the student filled them in.

After success, redirect to the course view — the plan is live immediately.

**Showing deadline status after setup / on the dashboard:**

Check `isOverDeadline` from the `/week` or `/plan` response. If `true`, show a warning:
```
⚠ At your current pace, you'll finish lectures on Aug 25 — but your exam is Sep 1
  with 14 revision days. You need to finish by Aug 18. Increase your daily hours.
```

Display logic:
```js
if (result.isOverDeadline) {
  const msg = `At your current pace you'll finish on ${result.projectedEndDate}, `
    + `but your deadline (exam ${result.examDate} − ${result.revisionDays} revision days) `
    + `is ${result.deadline}. Consider increasing your daily study hours.`;
  showWarningBanner(msg);
}
```

---

### 3. Dashboard / Home Screen — Next Lecture Card

Call on course home screen load:
```
GET /lecture/next
```

**Display:**
- Lecture name
- Subject name
- Duration of the segment (not full video if split) → `endSecond - startSecond` converted to `HH:MM`
- Scheduled date — if today show "Today", if tomorrow show "Tomorrow", else show date
- Status badge (see Status Badges below)
- If split: show "Part 2 of 3" label
- CTA button: "Watch Now" → opens video player at `startSecond`

**If response is `null`:** show "All lectures completed 🎉" state.

---

### 4. Dashboard — Previous / This / Next Week Overview

Call on the course dashboard/home screen to render the three-column (or three-tab) weekly overview:
```
GET /lecture/week-overview
```

**Display as three columns/tabs — Previous Week, This Week, Next Week:**

```
Previous Week (Jun 7 – Jun 13)     This Week (Jun 14 – Jun 20)     Next Week (Jun 21 – Jun 27)
  30 / 32 hrs · 2 hrs missed         32 hrs + 2 hrs catch-up          32 hrs
  ✓ Functions and Limits             ● Introduction to Calculus       ● Differentiation Rules
    Jun 9 · Done                       Today · [pending]                Jun 23 · [pending]
                                     ⟳ Functions and Limits
                                       Today · [overdue] · catch-up
```

**The hours header.** Each column's `hours` block drives the line under its title. Render `planned` and `carriedOver` as two visually distinct parts — `target` is just their sum, don't show it as one opaque number, since the whole point is that the student can see *why* this week is heavier than usual:

```js
const { planned, carriedOver, completed, remaining } = column.hours;

// This / next week — what they owe
const header = carriedOver > 0
  ? `${planned} hrs + ${carriedOver} hrs catch-up`   // highlight the second part
  : `${planned} hrs`;

// Previous week — what they managed
const past = `${completed} / ${planned} hrs`
  + (remaining > 0 ? ` · ${remaining} hrs missed` : '');
```

`previousWeek.hours.remaining` is that week's own shortfall — the hours that went into the backlog pool. `thisWeek.hours.carriedOver` is this week's equal share of that pool, so the two are equal only when this is the last week left.

**When the student can't catch up.** If `cannotCompleteInTime` is `true`, show a blocking warning rather than just a heavier week — no amount of carry-over will get them there:

```
⚠ You're 40 hrs behind with 2 weeks to your exam. Even filling every
  study day to 12 hrs you won't finish in time — move your exam date
  or raise your daily hours.
```

Use `carryOverHours` (the whole backlog) for that message, not `hours.carriedOver`, which is one week's share of it.

**Highlighting the carried lectures.** Items with `isCarryOver: true` are the lectures making up that `carriedOver` figure. Mark them distinctly (a ⟳ badge, a tinted row, a "catch-up" chip) so the student can see which specific lectures they are repaying, not just an hour count. Items with `isCarryOver: false` are the week's own planned work.

- `previousWeek.days[]` items use the `done` / `skipped` / `in_progress` / `late` vocabulary (see table below) — **not** the `pending`/`done_late` badges used for `thisWeek`/`nextWeek`, since these are actual activity records against what was planned.
- `thisWeek.days[]` and `nextWeek.days[]` use the same item shape and status badges as the [This Week View](#6-this-week-view) — render them the same way (bullets, recommended divider, per-day hour totals).
- `thisWeek` now spans the whole Sunday–Saturday week, including days already past — show elapsed days collapsed or greyed rather than assuming the first day is today.
- An empty `days: []` in any column means nothing was planned or done — show a muted "Nothing here" placeholder rather than leaving the column blank. Note the `hours` block can still be non-zero when `days` is empty (hours are owed, the cascade just had nowhere left to put them).

| `previousWeek` status | Meaning | Suggested label |
|---|---|---|
| `done` | Marked complete | Done |
| `skipped` | Explicitly skipped | Skipped |
| `in_progress` | Partially watched, not yet marked done | In Progress |
| `late` | Planned that week, never touched | Missed |

---

### 5. Video Player Integration

When the student clicks "Watch Now" on a plan item:

- Seek the video to `startSecond` on load
- Track progress normally (existing `UserToVideoInfo.seen` update calls)
- The segment is considered done when `seen >= endSecond` — the backend handles this automatically
- Do not auto-advance to the next segment if it belongs to the next day — show a "Come back tomorrow for Part 2" message instead

---

### 6. This Week View

Call on the weekly schedule screen:
```
GET /lecture/plan/weeks/v2   (GET /lecture/week was removed in #479)
```

**Display as a day-by-day list:**

```
Tuesday, June 18                          [2:00 hrs]
  ● Introduction to Calculus (Part 1/2)   1:00 hr   [pending]

Wednesday, June 19
  ● Introduction to Calculus (Part 2/2)   1:00 hr   [pending]
  ● Differentiation Rules                 45 min    [pending]
  ─ Recommended
  ○ Extra Practice Problems               30 min
```

- Required lectures shown as solid bullets `●`
- Recommended lectures shown under a "Recommended" divider as hollow bullets `○`
- Recommended lectures are informational only — no status badge, no tracking

**Total hours per day** shown on the right of the date header (`endSecond - startSecond` summed across all items for that day, converted to hours).

---

### 7. Full Plan View

Call when student opens "My Study Plan":
```
GET /lecture/plan
```

Same layout as the week view but shows the full list — including past days, not just upcoming ones. A day dated before today can only contain `done`/`done_late`/`skipped` items (anything not yet finished is always rescheduled to today or later), so past days can be shown collapsed by default with a "✓ all done" summary. An overdue lecture that's still not done doesn't sit under a past date — it's rescheduled forward like everything else, just badged `late` instead of `pending` wherever it lands.

If the screen groups by week instead (e.g. collapsible "Week 1", "Week 2" sections), call the week-grouped variant instead:
```
GET /lecture/plan/weeks
```
Render each `weeks[]` entry as a collapsible section labelled `Week {weekNumber}` (or the `weekStart`–`weekEnd` range), with its `days[]` rendered exactly like the week view. A week with an empty `days[]` array is an all-rest-days week — show it collapsed with a "No lectures scheduled" note rather than hiding it.

Show a summary bar at the top:
```
✓ 12 done   ⏱ 3 late   ● 45 pending   Finishes by: Aug 14
```

`Finishes by` date = last scheduled item date + buffer days.

---

### 8. Subject Progress View

Call for a syllabus-style "progress by subject" screen (e.g. a collapsible tree the student can drill into):
```
GET /lecture/subject-progress
```

**Display as a collapsible tree**, one row per node, each showing a progress bar/ring using `percentComplete`:

```
Mathematics                                    ▓▓▓▓▓▓░░░░ 60%  (12/20)
  ▾ Calculus                                    ▓▓▓▓▓░░░░░ 50%  (5/10)
      Limits and Derivatives                    ▓▓▓▓▓▓▓▓▓▓ 100% (4/4)
  ▸ Algebra                                     ▓▓▓▓▓▓▓░░░ 70%  (7/10)
```

- Render `subjects[]` at the top level; recurse into `children[]` for nested rows — the array is already sorted by `order`, don't re-sort client-side.
- Use `total`/`done` for the fraction label, `percentComplete` for the bar fill.
- `skipped`/`inProgress`/`notStarted` are available if you want a stacked/segmented bar instead of a single done-vs-remaining bar (e.g. grey for `notStarted`, amber for `inProgress`, red for `skipped`, green for `done`).
- If `unassigned.total > 0`, show it as a final "Other" row outside the subject tree — lectures with no subject tag still count in the student's overall progress even though they don't have a syllabus home.
- A leaf node (`children: []`) with `total: 0` means that node exists in the subject tree but has no `required` lectures tagged to it directly — hide or grey it out rather than showing "0%".

---

### 9. Status Badges

| Status | Badge colour | Label |
|---|---|---|
| `pending` | Grey | Upcoming |
| `done` | Green | Done |
| `done_late` | Yellow | Completed Late |
| `late` | Red | Overdue |
| `skipped` | Muted | Skipped |

---

### 10. Resume — Continue Where You Left Off

Call on course home screen load (alongside or after `/next`):
```
GET /lecture/resume
```

**If response is non-null:**
- Show a "Continue Watching" card above the Next Lecture card:
  ```
  ▶ Continue Watching
    Introduction to Calculus  ·  30:23 remaining
    [Resume]
  ```
- `Resume` button → open the video player and seek to `lastSeen` seconds immediately on load
- Show "Last watched: {relative time from `updatedAt`}" below the lecture name

**If response is `null`:** hide the card entirely.

**Relationship with `/next`:** Both can be shown simultaneously. `/resume` is for mid-video recovery; `/next` is the study plan's recommended next step. They may point to the same video (if the in-progress video is also today's scheduled lecture) or different ones.

---

### 11. Progress Saving — Periodic Heartbeat

While a video is playing, call `PATCH /lecture/progress` periodically so the resume position stays fresh.

```js
let progressTimer = null;

function startProgressSaving(videoId, playerEl) {
  progressTimer = setInterval(() => {
    const seen     = Math.floor(playerEl.currentTime);
    const lastSeen = seen;

    fetch('/api/lecture/progress', {
      method: 'PATCH',
      headers: {
        'Authorization': `Bearer ${getToken()}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ videoId, seen, lastSeen }),
    }).catch(() => {}); // fire-and-forget, don't block playback
  }, 12000); // every 12 seconds
}

function stopProgressSaving() {
  clearInterval(progressTimer);
  progressTimer = null;
}
```

**When to call it:**
- Start the timer when the video begins playing (`play` event)
- Stop the timer on pause, seek, end, or when the player unmounts
- Fire one final call immediately on pause/seek/end so the last position is always saved

**`seen` vs `lastSeen`:**
- `seen` — total seconds the student has watched (used by the study plan algorithm to detect partial progress). If the student rewinds, do not decrease `seen`. Only ever increase it: `seen = Math.max(currentSeen, playerEl.currentTime)`.
- `lastSeen` — the actual current playback position. Always set this to `playerEl.currentTime`.

```js
// Correct way to track seen (never decrease)
let maxSeen = 0;

playerEl.addEventListener('timeupdate', () => {
  maxSeen = Math.max(maxSeen, Math.floor(playerEl.currentTime));
});

// On save:
body: JSON.stringify({ videoId, seen: maxSeen, lastSeen: Math.floor(playerEl.currentTime) })
```

---

### 12. Updating the Study Plan

Provide a "Edit Study Plan" option in course settings. It opens the same setup form pre-filled with current values. On submit it calls the same `POST /lecture/plan` endpoint — the backend upserts and recalculates from today. Refresh the week/next views after success.

---

### 13. Flow Summary

```
Course open
    ↓
GET /check
    ↓
required: true? ──Yes──→ Show setup form → POST /plan → Course view
    ↓ No
Course view
    ↓
Home screen: GET /resume         →  "Continue Watching" card (seek to lastSeen)
             GET /next           →  Next Lecture Card
             GET /week-overview  →  Previous / This / Next Week columns
Week screen: GET /week    →  Weekly Schedule
Plan screen: GET /plan    →  Full Plan (flat)
             GET /plan/weeks  →  Full Plan (grouped by week)
Progress screen: GET /subject-progress  →  Subject Progress Tree

While watching:
    PATCH /progress every 12s  →  saves seen + lastSeen
    PATCH /progress on pause/end  →  final position flush
```
