# Bug Report: "Schedule a Call" bookings silently dropped or hidden for students already enrolled / with no self-booked callbacks

**Repos:** GrowthCommand (this repo, backend — root cause #1) and CRM-WEB (frontend — root cause #2)
**Reported by:** Student Success team lead (via Rohan Banerjee)
**Date:** 2026-09-29 (root cause #1), 2026-09-30 (root cause #2)
**Status:** Both root causes fixed and regression-tested (unit + full-suite zero-regression check both repos), pending code review / deploy
**Severity:** P0 — confirmed data loss / visibility loss on a customer-facing flow, affecting real students on aswinibajajclasses.com and every counsellor's Scheduled Calls screen. Recurring for ~2 months per Student Success.

## Summary

When a student submits the "Schedule a Call" widget (Call Back tab) for a course they're already enrolled in — or a batch/level underneath that course — the backend silently drops the request. No lead is updated, no activity is logged, no counsellor is notified, and (before temporary diagnostic logging was added for this investigation) nothing was logged anywhere. The student sees "Submitted Successfully!" but the CRM never receives the request.

## Root cause #1 (backend, GrowthCommand)

`checkNewContactForm` in `src/lead/lead.service.ts` (around lines 6377-6437) runs an "already enrolled" guard **before** any lead lookup, update, or notification:

```ts
if (contactForm.userId) {
  for (const course of contactForm.CourseNdPlatform) {
    if (course.courseId) {
      const isAlreadyInCourse = await this.databaseService.userToCourse.findFirst({
        where: {
          userId: contactForm.userId,
          OR: [
            { courseId: course.courseId },
            { Course: { OR: [ /* ...walks up to 5 parent levels... */ ] } },
          ],
        },
      });
      if (isAlreadyInCourse) {
        return; // <-- silent, unconditional exit. No lead update. No notification. No log.
      }
    }
  }
}
```

This appears to be intended to avoid re-marketing a course to someone who already bought it (e.g. via the generic Contact tab). It is applied identically to the Call Back tab, where the student is explicitly asking to be called — so an enrolled student's genuine callback request is treated the same as a marketing re-pitch, and thrown away.

## Evidence

Confirmed against real dev-database data and live testing (backend run locally against `GrowthDB_dev`, 2026-09-29/30):

- **Real lead, real data:** Student "Janowar/Rohan Banerjee" (`userId` 598, `UserLead.id` 6125) is enrolled in CFA Level 1 (May 2026 batch, `UserToCourse.id` 79 → `courseId` 100 → 92 → 2 → **1 ("Chartered Financial Analyst" / "CFA")**). A callback submission tagging "CFA" for this student never updates lead 6125 or notifies a counsellor.
- **Live-reproduced with temporary logging:** submitting a callback tagging CFA (course id 1) for this same student produced:
  ```
  [DIAG][checkNewContactForm] SUPPRESSED - contact form dropped, already enrolled in requested course or an ancestor of it {
    contactFormId: 5342, userId: 598, requestedCourseId: 1,
    matchedUserToCourseId: 81, matchedUserToCourseCourseId: 100
  }
  ```
- **Control test confirms the rest of the pipeline is healthy:** the same student submitting a callback for a course they are *not* enrolled in (FRM, course id 38) passed the guard, updated lead 6125 correctly, and dispatched to a counsellor's bucket immediately (appointment was within the 60-minute dispatch window). Lead lookup, update, dispatch, and counsellor-bucket visibility all work correctly — this is the only broken link.
- **Also ruled out as a cause:** the ~60-minute pre-dispatch assignment delay (`DISPATCH_LEAD_AHEAD_MINUTES`, `schedule-lead-dispatch.constants.ts:65`) is working as designed and is not related to this bug — verified live in both directions (armed for later when appointment is >1hr out; dispatched immediately when inside the window).

## Impact

Deterministic, not intermittent: **every** already-enrolled student who requests a callback tagging their own course (or a course under the same bundle) hits this every time. It looks intermittent only because it depends on who submits, not on timing — matching the reported "happens sometimes" pattern exactly, since only enrolled students are affected.

## Proposed fix

Scope the guard so it only suppresses the "treat this as a brand-new marketing lead" case, and never suppresses an explicit callback request. Concretely: only run the enrollment check (and its silent `return`) when `contactForm.appointmentTime` is **not** set — an explicit "Schedule a Call" submission always carries an `appointmentTime`, so this cleanly distinguishes a genuine callback booking from a generic course-interest ping, without needing any schema change or new field.

```ts
if (contactForm.userId && !contactForm.appointmentTime) {
  // ...unchanged...
}
```

This is a minimal, additive condition change — it doesn't touch the generic Contact-tab behavior (which keeps today's anti-re-marketing behavior), and it doesn't touch lead matching, dispatch, or notification logic at all.

**Status: implemented and verified.** Applied exactly as above (`src/lead/lead.service.ts`). Regression coverage added: `src/lead/lead.service.contact-form-enrollment-guard.spec.ts` (3 Jest tests — confirmed to fail against the old code, pass against the fix). Full backend Jest suite run before/after via JSON-diff: identical set of pre-existing failures in both runs (unrelated NestJS DI issues in other modules), zero new failures introduced.

## Root cause #2 (frontend, CRM-WEB)

Separately, even once a booking correctly reaches a counsellor's bucket, it can appear to "vanish" a few seconds after rendering. `src/store/slices/pages/classes/scheduled-call/scheduledCalls.ts`, `setMyScheduledCalls` reducer:

```ts
setMyScheduledCalls: (state, action) => {
  state.showMyScheduledCalls = true;   // forces the tab to "My Calls", unconditionally
  state.showNumbers = false;
  if (action.payload.length === 0) return;
  state.myScheduledCalls = action.payload;
  state.filteredScheduledCalls = action.payload;
},
```

Every page load fires both `giveScheduledCalls` and `giveScheduledSelfCalls`. The self-calls response is almost always `[]` (most counsellors have no self-booked callback pending). Sequence: (1) `existing-scheduled-lead` arrives, correctly populating the "All Calls" list — the counsellor sees their bookings; (2) `existing-self-scheduled-lead` arrives moments later with `[]`, and its handler **unconditionally** flips `showMyScheduledCalls` to `true`, regardless of payload or user action; (3) `ScheduledCallsContentWithFilters.tsx:23-27` derives what to render directly from `showMyScheduledCalls` — now `true` — so it renders `myScheduledCalls` (empty), silently hiding the correctly-populated "All Calls" list a few seconds after it rendered.

Confirmed live: reproduced exactly this appear-then-vanish sequence on the real dev environment for lead 6125 (employeeId 89) after a genuine CFA booking. This is deterministic on essentially every load (any counsellor with no self-booked callback pending), not timing-dependent — it also plausibly explains "fewer calls visible at login" and "extra calls appear later" from the original report (the data was never missing, just hidden behind the wrong tab until it's switched back).

**Fix:** `setMyScheduledCalls` should only store data, never decide which tab is active (that's `setShowMyScheduledCalls`'s job, triggered by explicit user action):

```ts
setMyScheduledCalls: (state, action) => {
  state.showNumbers = false;
  if (action.payload.length === 0) return;
  state.myScheduledCalls = action.payload;
  if (state.showMyScheduledCalls) {
    state.filteredScheduledCalls = action.payload;
  }
},
```

**Status: implemented and verified.** Applied exactly as above (CRM-WEB, `src/store/slices/pages/classes/scheduled-call/scheduledCalls.ts`). Regression coverage: `__tests__/store/slices/pages/classes/scheduled-call/scheduledCalls.test.ts` (5 Jest tests on the reducer directly — confirmed to fail against the old code, pass against the fix). Full CRM-WEB Jest suite run before/after via JSON-diff: the only difference between baseline and post-fix is this one new test going from failing to passing; zero other tests affected anywhere in the 1914-test suite.

## Secondary, optional (not a cause of either bug above, low priority)

`giveScheduledCallsInternal` (`lead.service.ts:3381-3397`) never emits `existing-scheduled-lead` back to the client when the result set is empty, unlike `giveScheduledSelfCallsInternal` which always emits (even `[]`). This is a minor UI-consistency gap — a counsellor's screen can't distinguish "confirmed zero calls" from "still loading" — but does not cause any booking to go missing. Worth a follow-up ticket, not blocking this fix.

## Out of scope / confirmed non-issues

- The 60-minute pre-dispatch assignment delay is working as designed and should not be changed.
