# Bug Report: Student Portal — Course Overview & Readiness

**Repo:** `SudentExamClub` (student-facing portal — not co-located with this repo; not inspected as part of this report, see Notes)
**Reported by:** Durgesh Tiwari
**Date:** 2026-07-10
**Status:** Open

> **Note on scope:** This report was written from the reporter's description of observed behavior only. The `SudentExamClub` codebase was not available to inspect from the machine this report was authored on (no GitHub access configured), so no root-cause investigation, file/line references, or code-level analysis is included. A developer with repo access should use this report as a starting point for reproduction and investigation, not as a diagnosis.

---

## Bug 1 — Profile → Overview always defaults to CUET course

**Summary:** From the Profile page, clicking into "Overview" (alongside the other dashboard links) always shows data for the CUET course, even when the logged-in user is not enrolled in / not associated with CUET.

**Steps to reproduce:**
1. Log in as a student who is **not** enrolled in the CUET course (e.g. enrolled only in some other course).
2. Go to Profile.
3. From the profile page (which lists Overview, Dashboard, and other links), click **Overview**.

**Expected behavior:** Overview should load default/current data for a course the user is actually enrolled in (e.g. their most recent/active course, or a course selected via some explicit default logic).

**Actual behavior:** Overview always selects/displays the CUET course, regardless of the user's actual enrollment.

**Impact:** Users not enrolled in CUET see irrelevant or empty data, and may be confused or blocked from seeing their real course overview. Likely a hardcoded default course (e.g. a hardcoded CUET course ID/slug, or a "first course in list" fallback that happens to resolve to CUET) rather than a per-user default.

**Suggested investigation areas:**
- Wherever "default course" is resolved when landing on Overview (frontend state/store default, or an API default param).
- Check for a hardcoded CUET course ID/slug used as a fallback instead of deriving the default from the user's actual enrollments.

---

## Bug 2 — Switching course via top-nav dropdown breaks navigation to Overview ("course doesn't exist")

**Summary:** Changing the selected course from the top navigation dropdown navigates the user to Overview, but Overview then reports that the course doesn't exist.

**Steps to reproduce:**
1. Log in as a student enrolled in at least one course.
2. From the top navigation bar, open the course dropdown and select a different course than the currently active one.
3. Observe that the app navigates to the Overview page.
4. Observe the error/message indicating the course does not exist.

**Expected behavior:** Selecting a course from the top-nav dropdown should navigate to that course's Overview and load its data correctly.

**Actual behavior:** Overview loads but reports the newly-selected course as non-existent.

**Impact:** Users cannot switch between their enrolled courses via the top-nav dropdown — this appears to block a core navigation flow.

**Suggested investigation areas:**
- Whether the dropdown passes the correct course identifier (id vs slug vs code) to the Overview route/query, and whether that identifier matches what the Overview data-fetch expects.
- Possible mismatch between the identifier used for routing (e.g. URL param) and the identifier used by the API/data layer to look up the course — this would also be worth checking against Bug 3, since both involve slugs/identifiers.

---

## Bug 3 — Readiness logic does not show readiness data even after adding slugs

**Summary:** The "readiness" feature does not display readiness data for a course/user even after slugs have been added (presumably to the course or related config, to satisfy whatever the readiness logic requires).

**Steps to reproduce:**
1. Add the required slug(s) to the course/entity that readiness logic depends on (as per current documented/expected process).
2. Navigate to wherever readiness is displayed for that course.
3. Observe that readiness still does not show.

**Expected behavior:** Once the necessary slug(s) are configured, readiness data should display correctly.

**Actual behavior:** Readiness remains blank/not shown, indicating the logic that gates readiness on slug presence is not correctly detecting or using the added slug(s).

**Impact:** Readiness — a feature students presumably rely on to track exam/course preparedness — is non-functional even when configured as instructed, suggesting either a bug in the slug-matching logic, a caching issue, or a mismatch between where slugs are being added and where the readiness logic reads them from.

**Suggested investigation areas:**
- Where readiness logic reads slug(s) from (course entity vs a separate mapping/config) vs. where slugs are actually being added — a mismatch here would fully explain the symptom.
- Any caching layer between slug configuration and readiness computation that might be serving stale (no-slug) state.
- Whether readiness has silent failure/error swallowing that hides why it isn't rendering (e.g. an API error being treated as "no data" instead of surfacing an error).

---

## Suggested next steps

1. Reproduce each bug with browser dev tools open (network tab) to capture the actual API calls/responses for Overview and readiness — this will quickly show whether these are frontend defaulting bugs or backend data bugs.
2. For Bug 2 in particular, compare the course identifier in the URL/route against the identifier the backend uses to look up the course — this is a common source of "doesn't exist" errors after a dropdown-driven navigation.
3. For Bug 3, confirm the exact location where "slugs" are being added and cross-reference against the readiness logic's data source.
