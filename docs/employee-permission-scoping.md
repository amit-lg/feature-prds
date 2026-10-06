# Employee Permission Scoping (Platform / Course)

## Overview

Extends the existing [Permission Assignment](employee-hierarchy-permissions.md#feature-2-permission-assignment)
feature. Today, a permission an employee has (direct grant, or via a group)
applies everywhere — there is no way to say "this employee can view leads,
but only for Platform X" or "only for Course Y".

This feature adds an opt-in **scope** on top of an existing grant:

- **No scope rows → global.** Unchanged from today's behaviour. Every
  `EmployeeToEmployeePermission` row and `EmployeePermissionGroupToEmployee`
  row that exists right now has zero scope rows, so nothing that already
  works changes.
- **One or more scope rows → restricted.** The grant only applies to the
  listed platform/course combinations.

This is a narrowing of an existing grant, not a second independent grant —
you can't scope a permission the employee doesn't already have (or hasn't
just been given, see below).

**Status:** Schema + management endpoints only (this doc). Nothing in the
app actually *enforces* scoped permissions yet — `EmployePermissionCheck.checkPermission()`
([src/common/utils/check-permission.ts](../src/common/utils/check-permission.ts))
still only checks "does this employee have this permission anywhere",
ignoring platform/course entirely. See [Open Work](#open-work) for what's
left.

---

## Schema

Two new tables, both added in migration `20260702081727_employeepermission`.

### `EmployeeToEmployeePermissionCourseNdPlatform` (direct grants)

```prisma
model EmployeeToEmployeePermission {
  id               Int      @unique @default(autoincrement())
  employeeId       Int
  permissionId     Int
  CourseNdPlatform EmployeeToEmployeePermissionCourseNdPlatform[]

  @@id([employeeId, permissionId])
}

model EmployeeToEmployeePermissionCourseNdPlatform {
  id                    Int       @id @default(autoincrement())
  employeePermissionId  Int
  platformId            Int?
  courseId              Int?
  Platform              Platform? @relation(fields: [platformId], references: [id])
  Course                Course?   @relation(fields: [courseId], references: [id])
  EmployeeToEmployeePermission EmployeeToEmployeePermission @relation(fields: [employeePermissionId], references: [id])
}
```

- `employeePermissionId` points at the specific `EmployeeToEmployeePermission`
  row (i.e. a specific employee + a specific permission), **not** at the
  employee or permission directly. Get to the employee via
  `EmployeeToEmployeePermission.employeeId`.
- `platformId` and `courseId` are both nullable and independent — a row can
  scope by platform only, course only, or both (course within a platform).
- Multiple rows per grant are allowed (e.g. "Course A" and "Course B" as two
  separate rows means the grant applies to either).

### `EmployeePermissionGroupToEmployeendCoursePlatform` (group grants)

Same shape, for permission groups:

```prisma
model EmployeePermissionGroupToEmployee {
  id                Int      @id @default(autoincrement())
  permissionGroupId Int
  employeeId        Int
  PlatformNdCourse  EmployeePermissionGroupToEmployeendCoursePlatform[]
}

model EmployeePermissionGroupToEmployeendCoursePlatform {
  id                        Int       @id @default(autoincrement())
  groupPermissionRelationId Int
  platformId                Int?
  courseId                  Int?
  Platform                  Platform? @relation(fields: [platformId], references: [id])
  Course                    Course?   @relation(fields: [courseId], references: [id])
  EmployeeToGroup           EmployeePermissionGroupToEmployee @relation(fields: [groupPermissionRelationId], references: [id])
}
```

`groupPermissionRelationId` points at the specific employee's membership row
in a group (`EmployeePermissionGroupToEmployee`), not at the group or
employee directly.

> **Note:** before this feature, nothing in the codebase ever created
> `EmployeePermissionGroupToEmployee` rows via an API — group membership was
> managed out-of-band (direct DB writes / admin tooling). The new
> `POST /command/permissions/group/scope` endpoint is the first API that can
> create one, as a side effect of scoping (see below).

### ⚠️ Pre-existing bug fixed alongside this feature

Three functions in `command.service.ts` — `getAllCourses`, `getAllowedCourses`,
`getAllowedPlatforms` (backing `GET /command/all-courses`, `/allowed-courses`,
`/allowed-platforms`) — already queried `EmployeeToEmployeePermissionCourseNdPlatform`
for course/platform access, written against the *old* shape of that table
(a direct `employeeId` column). The migration above replaced that with the
indirect `employeePermissionId → EmployeeToEmployeePermission.employeeId`
path, but those three call sites were never updated — nobody had re-run
`npx prisma generate` since, so the mismatch was silent. Fixed as part of
this change (now filters via `EmployeeToEmployeePermission: { employeeId }`).
**Run `npx prisma generate` after pulling this change**, or `npm run build`
will do it for you.

---

## New Permission-Scoping Endpoints

All under `/api/command`, all require `EmployeeAuthGuard` and the caller
having `canGivePermission` (same gate as the existing assign/revoke
endpoints). All the same subtree rules from
[employee-hierarchy-permissions.md](employee-hierarchy-permissions.md) apply:
caller can only scope permissions for employees in their own subtree, and
can only scope permissions/groups they themselves could grant (full parent
chain check, same as `POST /permissions/assign`).

These are **new, separate routes** — `POST /permissions/assign`,
`DELETE /permissions/revoke`, and their group-free semantics are completely
unchanged.

### `POST /command/permissions/scope`

Scope a direct permission grant to a platform and/or course. If the
employee doesn't already have the permission (or its ancestor chain), the
full chain is assigned globally first — same as `POST /permissions/assign`
— and only the requested leaf permission gets the scope row. **Ancestors
stay global**, they are not scoped (see [Open Work](#open-work)).

**Body:**
```json
{
  "employeeId": 8,
  "permissionId": 13,
  "platformId": 3,
  "courseId": 5
}
```
At least one of `platformId` / `courseId` is required.

**Response:**
```json
{
  "message": "Permission scope assigned successfully",
  "scope": {
    "id": 42,
    "employeePermissionId": 101,
    "platformId": 3,
    "courseId": 5
  }
}
```

**Validations:**
- Caller has `canGivePermission`
- `employeeId` is in caller's subtree
- Caller has `permissionId` and all its ancestors (same rule as `/permissions/assign`)
- `platformId` / `courseId`, if given, must reference existing rows
- Idempotent — re-scoping the same permission/platform/course combo returns the existing row instead of duplicating

---

### `DELETE /command/permissions/scope/:scopeId`

Removes one scope row by its own id (not by employee/permission — a grant
can have multiple scope rows, e.g. Course A and Course B as two separate
restrictions).

**Effect:** narrows nothing further — if this was the grant's last scope
row, the underlying permission grant **reverts to global** (per the "no
rows = global" rule). It does **not** delete the `EmployeeToEmployeePermission`
row itself; use `DELETE /permissions/revoke` for that.

**Validations:**
- Caller has `canGivePermission`
- The scope's owning employee must be in caller's subtree

---

### `POST /command/permissions/group/scope`

Scope a permission-group membership to a platform and/or course. If the
employee isn't already a member of the group, membership is created as a
side effect (see the note above — this is currently the only way to create
`EmployeePermissionGroupToEmployee` rows via API).

**Body:**
```json
{
  "employeeId": 8,
  "permissionGroupId": 4,
  "platformId": 3,
  "courseId": null
}
```
At least one of `platformId` / `courseId` is required.

**Response:**
```json
{
  "message": "Permission group scope assigned successfully",
  "scope": {
    "id": 7,
    "groupPermissionRelationId": 55,
    "platformId": 3,
    "courseId": null
  }
}
```

**Validations:**
- Caller has `canGivePermission`
- `employeeId` is in caller's subtree
- `permissionGroupId` exists
- Caller has every permission the group carries, and all their ancestors (union of chains) — same "can't give what you don't have" rule, applied to the whole group
- `platformId` / `courseId`, if given, must reference existing rows
- Idempotent, same as above

---

### `DELETE /command/permissions/group/scope/:scopeId`

Same shape as the direct-permission revoke, for group scopes. Does not
remove the employee's group membership itself, only the scope restriction.

**Validations:**
- Caller has `canGivePermission`
- The scope's owning employee must be in caller's subtree

---

## Extended Read Endpoint

`GET /command/permissions/employee/:employeeId` (existing endpoint,
unchanged URL/auth) now includes scope info per permission. This is
**additive** — existing fields (`id`, `name`, `source`) are unchanged, so
frontends that already consume this endpoint keep working without changes.

**Response:**
```json
{
  "employeeId": 8,
  "fname": "Vikram",
  "lname": "Kumar",
  "permissions": [
    {
      "id": 12,
      "name": "canViewClasses",
      "source": "direct",
      "isGlobal": true,
      "scopes": []
    },
    {
      "id": 13,
      "name": "canViewLeads",
      "source": "direct",
      "isGlobal": false,
      "scopes": [
        { "id": 42, "platformId": 3, "platformName": "UXL App", "courseId": 5, "courseName": "CFA Level 1" }
      ]
    },
    {
      "id": 15,
      "name": "canViewEnquiry",
      "source": "group",
      "groupId": 4,
      "isGlobal": false,
      "scopes": [
        { "id": 7, "platformId": 3, "platformName": "UXL App", "courseId": null, "courseName": null }
      ]
    }
  ]
}
```

| New field | Description |
|---|---|
| `isGlobal` | `true` when `scopes` is empty — the permission applies everywhere. |
| `scopes[]` | One entry per scope row. `platformName`/`courseName` are resolved server-side so the frontend doesn't need a second lookup. |
| `groupId` (group entries only) | The `EmployeePermissionGroup.id` this permission came from — new field, wasn't there before, needed so the frontend can call the group-scope endpoints. |

Note: for `source: "group"` entries, all permissions in that group share the
same `scopes` array, because the scope is on the *group membership*
(`EmployeePermissionGroupToEmployee`), not on individual permissions within
the group.

---

## Populating Platform / Course Pickers

Don't build new list endpoints for this — reuse what already exists:

| Purpose | Endpoint |
|---|---|
| Platforms the caller can see | `GET /command/allowed-platforms` |
| Courses the caller can see | `GET /command/allowed-courses` or `GET /command/all-courses` |

(These are the same three functions fixed above — `getAllowedPlatforms`,
`getAllowedCourses`, `getAllCourses` in `command.service.ts`.)

---

## Frontend Instructions

### Where this lives

Extends the **Permissions tab** of the Employee Detail Panel described in
[employee-hierarchy-permissions.md §4](employee-hierarchy-permissions.md#4-employee-detail-panel).
No new sidebar section — this is a refinement of the existing "Assign
Permission" modal, plus a new indicator on each permission row.

### 1. Permission row — show scope

For each permission returned by `GET /command/permissions/employee/:id`:

```
┌──────────────────────────────────────────────────────┐
│ ● canViewLeads         [Scoped: UXL App / CFA L1] [Revoke] │
│ ● canViewClasses                          [Global] [Revoke] │
└──────────────────────────────────────────────────────┘
```

- `isGlobal: true` → show a "Global" badge
- `isGlobal: false` → show a "Scoped" badge; on hover/click, list every
  entry in `scopes[]` as `platformName / courseName` (fall back to just
  whichever of the two is non-null)
- Clicking the badge opens a small popover with an "Add scope" / "Remove
  scope" action per row (see below) — this is separate from the main
  "Revoke" button, which still fully removes the permission (`DELETE /permissions/revoke`)

### 2. Assign Permission modal — add scope fields

Extend the existing modal from
[employee-hierarchy-permissions.md §4](employee-hierarchy-permissions.md#4-employee-detail-panel):

```
┌──────────────────────────────────────────┐
│  Assign Permission to Vikram             │
│                                          │
│  Select permission:                      │
│  [ Search permissions...           ▼ ]  │
│                                          │
│  Scope (optional):                       │
│  Platform: [ Select platform      ▼ ]   │
│  Course:   [ Select course        ▼ ]   │
│                                          │
│  ⚠ This will also add:                  │
│    · canViewEnquiry                      │
│    · canViewClasses                      │
│    (these stay global — not scoped)      │
│                                          │
│  [Cancel]              [Assign]          │
└──────────────────────────────────────────┘
```

- Platform dropdown ← `GET /command/allowed-platforms`
- Course dropdown ← `GET /command/allowed-courses` (optionally filtered by
  the selected platform client-side, if the platform/course relation is
  available from `PlatformToCourse` elsewhere in the app)
- Both fields blank → call `POST /permissions/assign` (existing, unscoped)
- Either field filled → call `POST /permissions/scope` instead, with
  `platformId`/`courseId` included
- Show the "also adds ancestors" warning as today, but clarify (as above)
  that ancestors are added **globally**, not scoped — only the leaf
  permission gets the platform/course restriction

### 3. Adding an additional scope to an already-granted permission

For a permission the employee already has (`isGlobal: false` with existing
scopes, or `isGlobal: true` and you want to narrow it going forward):

- "Add scope" button next to the permission row → small form with
  Platform/Course dropdowns → `POST /permissions/scope`
- Note: scoping an `isGlobal: true` permission does **not** remove its
  global access retroactively for other platforms — global access and
  scope rows aren't mutually exclusive at the data level (enforcement logic
  decides precedence once it's built — see Open Work). For now, treat
  "Global" and "has scopes" as separate facts you're just displaying, not a
  toggle.

### 4. Removing a scope

- Each entry in the scope popover has its own "Remove" — calls
  `DELETE /permissions/scope/:scopeId` (or `/permissions/group/scope/:scopeId`
  for group-sourced permissions)
- Refresh `GET /command/permissions/employee/:id` after any scope mutation

### 5. Group-sourced permissions

- Group rows (`source: "group"`) still show no per-permission "Revoke"
  button (unchanged from today — "manage groups separately")
- They now *can* show scope info and an "Add/Remove scope" action, using
  `groupId` from the response and the `/permissions/group/scope*` endpoints
- Tooltip should clarify: scoping here scopes the *entire group membership*
  for this employee, not just one permission within it

---

## Open Work

This pass only builds the write/read management surface. Still open, in
roughly the order they'd need to happen:

1. **Enforcement.** `EmployePermissionCheck.checkPermission()` needs a
   platform/course-aware variant (e.g. `checkPermission(name, employeeId, { platformId, courseId })`)
   that: finds the grant, and if it has scope rows, requires the passed
   context to match one of them; if it has none, passes as global (today's
   behaviour). This needs auditing every call site — there are 100+ across
   the codebase — to decide which ones have platform/course context
   available and should switch to the scoped variant, vs. which should stay
   global (e.g. `canGivePermission` itself probably never needs scoping).
2. **Ancestor scoping.** Right now scoping a permission's leaf only —
   ancestors from the auto-add chain stay global. Decide whether ancestors
   should optionally inherit the same scope (would need a design decision
   on what happens when the same ancestor is required, globally, by a
   *different* already-assigned permission).
3. **Group membership management.** There's still no general-purpose
   "add/remove employee from group" endpoint — `POST /permissions/group/scope`
   creates membership only as a side effect of scoping. If group membership
   needs to be managed independently of scoping, that's a separate feature.
4. **Revoke-scope UX for "last scope row."** Confirm with product whether
   removing the last scope row silently reverting to global is the desired
   behaviour, or whether it should instead fully revoke the permission.
