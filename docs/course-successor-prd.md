# PRD: Course Successor Management

**Status:** Draft
**Author:** Durgesh Tiwari (via Claude Code)
**Date:** 2026-07-18
**Repo:** GrowthCommand (backend) — admin CRUD consumed by the Command (admin) panel, read surface consumed by the student portal

---

## 1. Summary

When a student finishes a course today, nothing in the product tells them what to do next. They either drop off or have to browse the full course catalog themselves. **Course Successor Management** lets a content/course admin curate one or more explicit "next course" recommendations per course — ranked, labeled, and independently activatable — so a student who completes a course sees a deliberate next step instead of a dead end.

This is a new, self-contained relationship layered on the existing `Course` model:

```
Course (completed)  ──CourseSuccessor──►  Course (recommended next)
```

The schema for this already exists (`CourseSuccessor` in `prisma/schema.prisma`, a join table following the same shape as `CourseCategoryToCourse` / `CourseSubjectToCourse`). This PRD scopes the admin management API and the student-facing read API on top of it.

---

## 2. Background

`Course` already has a self-relation (`Course.courseId` → `CoursesToCourse`) used to group child courses under a parent (e.g. a bundle or batch structure). Overloading that field for "what to take next" would conflate two unrelated concepts — parent/child grouping is structural, successor is a recommendation. `CourseSuccessor` is deliberately a separate model:

```prisma
model CourseSuccessor {
  id                Int      @id @default(autoincrement())
  courseId          Int
  successorCourseId Int
  order             Int?
  label             String?
  isActive          Boolean? @default(true)
  createdAt         DateTime @default(now())
  updatedAt         DateTime @updatedAt
  Course            Course   @relation("CourseSuccessors", fields: [courseId], references: [id])
  SuccessorCourse   Course   @relation("CourseSuccessorOf", fields: [successorCourseId], references: [id])

  @@unique([courseId, successorCourseId])
}
```

A course's completion state already exists per-user via `CourseUserMeta.isCompleted` (`src/database` — `userId` + `courseId` + `isCompleted`), which is the natural trigger point for showing successors on the student side, though this PRD does not require the successor endpoint itself to be gated on completion (see §8.4, §9).

---

## 3. Problem statement

- There is currently no structured "what's next" signal anywhere in the schema or API. Any next-course suggestion today is either absent or handled entirely outside the product (e.g. a counselor call, a WhatsApp message).
- Content/course admins have no way to express "students who finish Course A are best served by Course B, or failing that, Course C" — a common pattern for tiered programs (Foundation → Advanced), certification tracks, or cross-sells (exam prep → interview prep).
- Course completion is a moment of high intent — a student who just finished is more likely to act on a recommendation than one browsing cold. That moment is currently wasted.

## 4. Goals

1. Let an admin attach one or more successor courses to a course, each independently ordered and labeled.
2. Let an admin curate without deleting — successors can be deactivated (`isActive: false`) and reactivated rather than removed and re-created, preserving `order`/`label`.
3. Expose an endpoint the student portal can call to render "what's next" for a course, returning only active successors in rank order.
4. Keep the data model simple and admin-curated for v1 — no recommendation engine, no scoring.

## 5. Non-goals

- No automatic/algorithmic recommendation (e.g. based on quiz performance, purchase history, or cohort behavior). Every successor edge is explicitly created by an admin. See §9 for a possible v2 direction.
- No changes to enrollment, cart, or checkout flow. This feature only surfaces a recommendation; acting on it (enrolling in the successor course) goes through the existing course purchase/enrollment path unchanged.
- No student-facing UI — this PRD covers the backend API only; the student portal team owns how/where "what's next" is rendered.
- Not a replacement for `Course.courseId` parent/child grouping — that relation is untouched.
- No cross-platform scoping in v1: a `CourseSuccessor` mapping is global (not per-`Platform`), consistent with `Course` itself not being platform-scoped (platform association happens via `PlatformToCourse`). If a successor needs to differ by platform, that's a v2 extension (see §9).

## 6. Users

- **Content/Course admin (employee)** — primary user for the management side; curates successor mappings from the Command panel.
- **Student** — consumes the recommendation, typically on a "course completed" / certificate / dashboard screen.

## 7. User stories

1. As a course admin, I can list a course's current successors (active and inactive) so I can see what's already configured before making changes.
2. As a course admin, I can add a successor course with an optional `order` and `label` (e.g. "Recommended next", "For deeper practice"), so students understand *why* it's being suggested.
3. As a course admin, I can add more than one successor to the same course and control their relative order, so I can offer a primary recommendation plus alternatives.
4. As a course admin, I can deactivate a successor mapping (e.g. a course is temporarily unavailable) without losing the configured order/label, and reactivate it later.
5. As a course admin, I cannot accidentally make a course its own successor, and cannot create the same successor mapping twice — the API rejects both.
6. As a course admin, if I try to link a successor course that doesn't exist, I get a clear `404` rather than a silent failure or a foreign-key error.
7. As a student, once I finish a course, the app can fetch that course's active successors in order, so it can show me a clear next step.

## 8. Functional requirements

### 8.1 Admin endpoints (Command module, `EmployeeAuthGuard`)

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/course/:courseId/successors` | List all successor mappings for a course (active + inactive), ordered by `order ASC NULLS LAST, id ASC`. Includes basic successor course fields (`id`, `name`, `abbr`) so the admin UI doesn't need a second lookup. |
| `POST` | `/course/:courseId/successors` | Create a mapping. Body: `{ successorCourseId: number, order?: number, label?: string, isActive?: boolean }`. |
| `PATCH` | `/course/successors/:id` | Update `order`, `label`, `isActive`, or `successorCourseId` on an existing mapping. All fields optional. |
| `DELETE` | `/course/successors/:id` | Hard-delete a mapping. (Prefer `PATCH isActive: false` for routine curation; `DELETE` is for removing a mapping created in error.) |

### 8.2 Validation & business rules

- `successorCourseId` (and `courseId` on the path) must reference an existing `Course` → `404 Course not found` / `404 Successor course not found`.
- `courseId === successorCourseId` → `400 A course cannot be its own successor`.
- Duplicate `(courseId, successorCourseId)` → `409 Conflict` (backed by the schema's `@@unique([courseId, successorCourseId])`, matching the pattern already used for `FaqToCourseNdPlatform`).
- On `PATCH` that changes `successorCourseId`, re-run both the existence check and the self-reference check against the mapping's (possibly unchanged) `courseId`.
- No cycle detection required — unlike `CourseCategory`'s parent/child tree, `CourseSuccessor` is not a strict hierarchy. A ↔ B (A recommends B, B recommends A) is valid and expected for programs that cross-sell each other.

### 8.3 Ordering

Same convention as `FaqQuestion`/`FaqSubject` (`docs/faq-admin.md`): sort by `order ASC` with `NULL`s last, then `id ASC` as a stable tiebreaker. Sorting happens in application memory after a single `findMany`, consistent with existing admin list endpoints at this scale (a course is expected to have a handful of successors, not hundreds).

### 8.4 Student-facing endpoint

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/course/:courseId/successors/active` | Returns only `isActive: true` mappings for the course, ordered per §8.3, shaped for display (`successorCourseId`, `name`, `abbr`, `label`, `order`). |

Guarded by `AuthGuard` (student token). **Not** gated server-side on the student having completed `courseId` — the endpoint just answers "what are this course's active successors." Whether/when to call it (e.g. only after `CourseUserMeta.isCompleted` flips true) is a frontend decision. This keeps the endpoint simple and reusable (e.g. also useful on a course's marketing/detail page, not just post-completion) — flagged as a decision to confirm with product, see §9.

### 8.5 Permissions

Admin endpoints should reuse whatever permission keys already gate course-level admin actions in `src/common/utils/check-permission.ts`, rather than introducing a new key namespace. Proposed (pending confirmation against the actual permission tree — `permissionsStrings.txt` lists `canViewCourse`/`canAlterCourse` as the aspirational course-admin keys):

| Action | Permission |
|---|---|
| `GET` (list, admin) | `canViewCourse` |
| `POST`, `PATCH` | `canAlterCourse` |
| `DELETE` | `canAlterCourse` |

The student-facing `GET .../active` route only needs `AuthGuard`, no permission check.

## 9. Open questions / decisions needed before build

| # | Question | Recommendation | Owner |
|---|---|---|---|
| 1 | Should the student-facing endpoint be gated server-side on course completion (`CourseUserMeta.isCompleted`), or left open for the frontend to decide when to call it? | Leave open (§8.4) — simpler, more reusable; revisit if abuse/scoping becomes a concern. | Product |
| 2 | Should successor mappings be platform-scoped (a course's successor could differ by platform/tenant)? | Ship global for v1 — `Course` itself isn't platform-owned, platform association is a separate join (`PlatformToCourse`); add a `platformId` column later if a real case surfaces. | Product |
| 3 | Exact permission key names for admin CRUD (§8.5) | Confirm against the live permission tree in `check-permission.ts` before implementation — `canViewCourse`/`canAlterCourse` are proposed based on `permissionsStrings.txt`, may not match what's actually wired in code. | Engineering |
| 4 | Should there be a cap on number of successors per course? | No hard cap for v1 — expected to be single digits; add a soft warning in the admin UI (not server-enforced) if it grows past ~5. | Product/Design |
| 5 | v2: algorithmic/personalized successor suggestions (based on quiz score, subject weakness, purchase history)? | Out of scope for v1; the admin-curated `CourseSuccessor` table remains the source of "eligible" suggestions even if a future ranking layer picks among them. | Product |

## 10. Implementation notes (for engineering, non-binding)

- Model already added to `prisma/schema.prisma` (`CourseSuccessor`, with `Successors`/`SuccessorOf` back-relations on `Course`). Migration (`npx prisma migrate dev --name add_course_successor`) and `npx prisma generate` are the user's own next step, not yet run.
- Natural home for the four admin routes is wherever existing course-admin endpoints live in the Command module (`src/command/command.controller.ts` / `command.service.ts`), following the same DTO-per-route pattern as `docs/faq-admin.md` (`create-course-successor.dto.ts`, `update-course-successor.dto.ts`).
- The student-facing route can live in whichever module already exposes student-facing course reads (check for an existing `course`-adjacent controller under the `auth`/user-facing path rather than `command`), guarded by `AuthGuard` + `PlatformCheckMiddleware` per the standard module conventions in `CLAUDE.md`.
- Existence/self-reference/duplicate checks (§8.2) should run before the DB write, mirroring the validation order already used in `FaqSubject`'s reparent checks (`docs/faq-admin.md` §Business Rules).

## 11. Success metrics

- % of students who, after completing a course, enroll in (or at least view) one of its active successor courses within N days — the core signal that this feature drives the intended next action.
- Number of courses with at least one active successor configured (adoption by the content team — a feature nobody curates has no downstream effect).
- Drop-off rate immediately after course completion, before vs. after successors are configured for that course.

## 12. Related docs

- `docs/course-models.md` — `Course` schema background, including the existing parent/child self-relation this feature deliberately does not reuse.
- `docs/faq-admin.md` — closest existing precedent for this PRD's admin CRUD shape (create/update/delete on a mapping table, ordering convention, uniqueness-as-409 pattern).
- `docs/course-transfer-admin-api.md` — another course-admin-facing feature; reference for how course-scoped admin routes and permission checks are typically documented.
