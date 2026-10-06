# Employee Courses & Breaks HTTP API

The HTTP counterpart to a subset of the `/employee` socket's non-calling, non-login, non-chat, non-presence events (admin-web's "remaining REST endpoints" split, GrowthCommand — Phase 3, socket removal). **Sockets are not going away** — `src/employee/employee.gateway.ts` keeps every handler below exactly as-is; these endpoints are additive.

Frontend counterpart: admin-web's Courses and Breaks page conversions (admin-web #42 depends on this ticket).

Covers: **Courses** (`getCourseMeta`, `addCourseMeta`) and **Breaks/attendance** (`checkForBreak`, `employeeBreak`, `attendance`) — the last group is shared with crm-web's `BreakPopOver.tsx`/`HomeContainer.tsx`, so both frontends consume the same endpoints documented here.

**Explicitly out of scope** (see GrowthCommand #309): `unlockUSB` / `requestUSB` / `openUSB` stay socket-only — they're shared with the Platform feature's `USBIndicator.tsx`/`editUserDevice` flow, not device-page-exclusive, and are not converted here.

---

## Authentication

Every endpoint below requires:

```
Authorization: Bearer <employee_jwt>
```

plus a resolvable platform, exactly like every other `/api/command` route:

```
Origin: <platform origin>
```
or
```
dauth: <platform auth key>
```

The `EmployeeAuthGuard` (`path: 'command'`) enforces this and sets the acting employee from the token — no request accepts a client-supplied employee/user id. There is no socket `login` step for these endpoints; login stays on sockets.

All routes are on the existing `command` controller, base path `/api/command`.

---

## Course meta

### Get course meta

Replaces socket event: `getCourseMeta` / `getCourseMetaSocketSuccess`

```
GET /api/command/course-meta/:courseId
```

Requires the `canViewCourse` employee permission (`403` otherwise).

**Response** `200` — the course's meta row, or `null` if none has been created yet:

```json
{
  "id": 5,
  "courseId": 42,
  "shortDescription": "...",
  "longDescription": { "...": "..." },
  "price": 999,
  "purchasable": true,
  "hours": 40
}
```

### Add / update course meta

Replaces socket event: `addCourseMeta` / `addCourseMetaSuccess`

```
POST /api/command/course-meta
```

This endpoint already existed prior to this ticket (`PlatformService.addCourseMeta`) and is the REST equivalent already in use — no change was made to it here. Requires `canCreateCourse`. Accepts `multipart/form-data` (`courseId` or `courseMetaId`, `shortDescription`, `longDescription`, `price`, `isPurchasable`, `hours`, optional `uploadedFiles`).

---

## Breaks & attendance

These three replace the corresponding `/employee` socket events. The socket versions track `attendanceId`/`breakId` on the live socket connection (set at socket `login`); since HTTP requests are stateless, each call below re-derives the employee's current open attendance record (`checkOut: null`, most recent `checkIn`) and its open break (`breakEnd: null`) from the database instead. Business rules (one open break per attendance, break start/end toggling) are unchanged.

### Check break status

Replaces socket event: `checkForBreak` / `break`

```
GET /api/command/break
```

**Response** `200`:

```json
{ "break": true }
```

`break: false` if there's no open attendance record or no open break on it.

### Start / end a break

Replaces socket event: `employeeBreak` / `break-start-success` / `break-start-error` / `break-end-success` / `break-end-error`

```
POST /api/command/break
```

Toggles: starts a break if none is open, ends the open one otherwise.

**Response** `200`:

```json
{ "break": true, "message": "Break started successfully" }
```
or
```json
{ "break": false, "message": "Break ended successfully" }
```

**Errors**: `400 Bad Request` — *"You must be checked in to start or end a break"* — if the employee has no open attendance record (i.e. hasn't checked in via the socket `login` flow, which is unchanged).

### Get attendance + breaks for a day

Replaces socket event: `attendance` / `attendance`

```
GET /api/command/attendance?date=2026-09-16
```

`date` is optional (ISO date string) and defaults to now. The day is resolved as a full IST calendar day, matching the socket handler.

**Response** `200`:

```json
{
  "attendance": [{ "id": 1, "employeeId": 42, "checkIn": "...", "checkOut": null }],
  "breaks": [{ "id": 9, "attandenceId": 1, "breakStart": "...", "breakEnd": null }]
}
```
