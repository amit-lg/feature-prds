# Employee Management — Frontend PRD

Status: Draft
Owner: TBD
Source: audit of `src/employee/employee.gateway.ts`, `src/employee/employee.service.ts`, `src/command/command.controller.ts`, `src/command/command.hierarchy.service.ts`, `src/device/`, `src/auth/guards/employee-auth.guard.ts`, `src/common/utils/check-permission.ts`, `permissionsStrings.txt`
Related docs: `docs/employee-hierarchy-permissions.md`, `docs/employee-permission-scoping.md`, `docs/employee-communication.md`, `docs/ticket-system.md`

## 1. Summary

"Employee management" is already fully implemented server-side but split across two transports that a frontend has to integrate independently:

- **REST** (`/command/*`, `EmployeeAuthGuard`, JWT bearer) — org hierarchy, permission/group assignment, lead-source assignment. Backed by `command.controller.ts` / `command.hierarchy.service.ts`.
- **Socket.IO `/employee` namespace** (`employee.gateway.ts`) — session/login, presence, employee directory, employee creation, device management, attendance & breaks. Authorization here is **not** guard-based; it's Socket.IO room membership set at socket-login time (`client.rooms.has('canViewDevice')`, etc.).

There is no existing employee-management UI. This PRD scopes a frontend that covers: session/login, employee directory & onboarding, org hierarchy, permissions & groups, device management, and attendance/breaks. Lead assignment, calling, and chat are separate concerns with their own docs (`docs/calling-dashboard-mis-export-design.md`, `docs/employee-communication.md`) and are **out of scope** here except where the employee-management UI needs to link into them (e.g. assigning lead sources to an employee).

## 2. Scope

**In scope**
- Login/session (dual REST + socket)
- Employee directory (list, online presence, search)
- Employee onboarding/creation
- Org hierarchy (tree view, assign/move/remove reports)
- Permissions & permission groups (grant/revoke, scoping to platform/course)
- Device management (list, allow/disallow, USB unlock, rename, type change)
- Attendance & break tracking (self + admin view)

**Out of scope (separate PRDs/docs)**
- Lead/call-center console (`docs/calling-dashboard-mis-export-design.md`)
- Employee chat (`docs/employee-communication.md`, `docs/employee-chat-moderation-design.md`)
- Ticketing (`docs/ticket-system.md`)

## 3. Personas & permission gating

There's no role enum — access is entirely permission-string-driven (tree in `permissionsStrings.txt`, enforced via Socket.IO room membership on `/employee` and via `commandHierarchyService`'s permission checks on REST). Every screen below must be conditionally rendered/hidden based on the permission list returned at login (`employeepermissions` socket event / `GET /command/permissions`), not on a hardcoded role. Treat "does the current employee have permission X" as a client-side capability check that mirrors server-side enforcement — never assume a control is safe to show just because an endpoint exists.

Key gates referenced throughout:

| Permission | Gates |
|---|---|
| `canViewEmployee` | View employee directory |
| `EmployeeAdd` | Create employee (note: gateway checks this literal room name, not `canAddEmployee` from the permission doc — see §7 gaps) |
| `canViewDevice` | View device list/status |
| `canAllowDevice` | Toggle device allow/disallow |
| `canAllowEmployeeToDevice` | Toggle employee↔device pairing |
| `canChangeDeviceType` | Change device type |
| `canOpenUSB` | Remote USB unlock |
| `canChangeDeviceName` | Rename device |
| `canGivePermission` | All hierarchy + permission-assignment screens |
| `canViewLeads` | Lead-source assignment screen (adjacent, in-scope for the assignment UI only) |

## 4. Session & auth (dual-transport — must be modeled explicitly)

This is the most important integration detail for the frontend and should be built as a single session module, not ad hoc per screen.

1. **REST login**: `POST /command/login` with `CommandLoginDto { deviceId, email, password }` → `{ accessToken, refreshToken, employee }`. `accessToken` is a JWT (`{ employeeId, platformId, deviceId, path: 'command' }`) used as `Authorization: Bearer <token>` for all `/command/*` calls.
   - There is **no `/command/refresh` endpoint currently wired** — the frontend cannot silently refresh on 401 yet. Flag as a blocking backend gap (§7) if session length needs to exceed JWT expiry.
   - `POST /command/logout` is a server stub that throws — do not build a "logout" button that depends on it succeeding; logout must be client-side token discard + closing the socket.
2. **Socket login**: after the app connects to `/employee` (passing `dauth` header/query and `deviceId` in the handshake query), it must **separately** emit `login` with `{ email, password }` (plaintext — see §7) to establish `client.employeeId` on that socket and receive `loginsuccess`, `onlineEmployees`, `employeepermissions`. The socket connection is otherwise inert (most events require `client.employeeId` or a permission room to be set).
   - This means the login screen effectively performs two independent auth calls with the same credentials. Do both on submit; treat the REST call as the source of truth for the stored session/token, and the socket `login` as required to unlock realtime features (presence, device ops, employee directory, attendance).
   - **Only one socket session per employee is allowed at a time** — a second `login` while the employee already has a live socket in `online_employee` is rejected with `loginError`. Surface this as "already logged in on another device" rather than a generic error.
   - Device pairing gate: login (both REST and socket) fails unless the connecting device has an `EmployeeToDevice.isAllowed = true` row for this employee. First-time connection from a new device silently creates a `isAllowed: false` pairing and denies login — the UI needs a clear "this device is not yet authorized, ask an admin to allow it in Device Management" state rather than a bare error toast, since there's no self-service path.
3. Reconnect handling: on socket reconnect, `employeeId` does not persist automatically — the frontend must re-emit `login` (or the app should treat any socket reconnect as requiring re-auth of the realtime layer, independent of whether the REST JWT is still valid).

## 5. Feature areas & screens

### 5.1 Employee Directory

- **List**: socket `employeeDetails` (emit, listen for `employeeDetails` reply) → all employees + computed `isOnline`. Gate: `canViewEmployee`.
- **Presence updates**: subscribe to room broadcasts `cameOnline` / `employeelogout` (both to room `online_employee` on `/employee`) to live-update the online badge without re-polling.
- **Legacy note**: `getHierarchy`/`hierarchy` event dumps *all* employees flat and is superseded by the REST hierarchy tree (§5.3) — don't build new UI against it.
- **Search**: no dedicated employee search endpoint was found; filter client-side over the directory payload for v1.

### 5.2 Employee Onboarding (Create)

- Socket emit `addEmployee` with `{ fname, lname, email, profile? }`, gate: room `EmployeeAdd`. Listen for `employeeCreated` / `employeeCreateError`.
- **Important limitation**: this only creates the bare `Employee` row with a random placeholder password (`uuidv4()`, never surfaced anywhere). It does **not**:
  - Set up `EmployeeWork` (team, designation, company) or `EmployeePersonal` (contact/bank/emergency info) — no endpoint for either was found in this module.
  - Assign any permissions, groups, or hierarchy placement.
  - Deliver credentials to the new employee (no email/invite flow wired here).
  - The frontend onboarding flow therefore cannot be a single "create employee" form that results in a usable account — it must be a **multi-step wizard**: (1) create bare record, (2) immediately chain into hierarchy assignment (§5.3) and permission/group assignment (§5.4), and (3) flag credential delivery as an unresolved manual step until a backend "set initial password / send invite" endpoint exists (§7).
  - Recommend surfacing this limitation prominently in the UI (e.g., a post-creation checklist: "Set reporting manager", "Assign permissions", "Share login credentials manually") rather than implying onboarding is complete after step 1.

### 5.3 Org Hierarchy

Backed entirely by REST (`command.hierarchy.service.ts`), gate: `canGivePermission` (hierarchy admin is folded into the same permission as permission-granting) plus target-employee-in-caller's-subtree checks enforced server-side on every mutating call.

- `GET /command/hierarchy/tree` — nested tree for the caller's subtree → render as an org chart (expand/collapse).
- `GET /command/hierarchy/flat` — flat list for pickers (e.g. "assign manager" dropdowns).
- `POST /command/hierarchy/assign` `{ upperEmployeeId, lowerEmployeeId }` — add a reporting edge (additive; an employee can have multiple managers).
- `DELETE /command/hierarchy/remove` `{ upperEmployeeId, lowerEmployeeId }` — remove one edge; server enforces the employee retains ≥1 manager, so the UI must not allow removing the last remaining edge (show it disabled with a tooltip rather than letting the call fail).
- `POST /command/hierarchy/move` `{ lowerEmployeeId, newUpperEmployeeId }` — drag-and-drop re-parenting; this **replaces all** existing manager edges with the single new one (not additive like `assign`). Model the org-chart drag interaction on this endpoint, and treat "add an additional manager" (matrix reporting) as a separate explicit action using `assign`, since the two are not interchangeable.
- Server enforces cycle prevention and "can't move under own subtree" — surface these as inline validation errors from the API response, not client-side guesses.

### 5.4 Permissions & Permission Groups

Gate: `canGivePermission`, all scoped to the caller's subtree.

- `GET /command/permissions/grantable` — permissions the current admin is allowed to grant (their own full ancestor chain) — use this to populate the "add permission" picker, not the full catalogue, so an admin can't grant permissions above their own level.
- `GET /command/permissions/employee/:employeeId` — an employee's current permissions, each tagged `source: 'direct' | 'group'` plus any `scopes[]`. Render direct grants and group-inherited permissions distinctly (group-sourced ones aren't individually revocable — see below).
- `POST /command/permissions/assign` `{ employeeId, permissionId }` — grants the permission **and its full ancestor chain automatically**. UI should communicate this ("granting X will also grant its parent permissions Y, Z") rather than surprise the admin with extra rows appearing.
- `DELETE /command/permissions/revoke` `{ employeeId, permissionId }` — only revokes **direct** grants; attempting to revoke a group-sourced permission from this screen will not work as expected — the UI must route the admin to remove them from the group instead, or disable the revoke action for `source: 'group'` rows.
- Scoping (platform/course-limited grants) — `POST /command/permissions/scope` / `DELETE /command/permissions/scope/:scopeId` for direct grants, and the `/group/scope` equivalents for group memberships. **Flag clearly in the UI that scoping is not yet enforced server-side** (see §7) — today a "scoped" grant still behaves as global everywhere permission checks actually run. Either hide this UI until enforcement ships, or label it explicitly as "configured but not yet enforced" so admins don't rely on it for access control.
- Permission Groups: endpoints for group CRUD/membership were not enumerated in the audited surface beyond scope-assignment — confirm with backend before building group create/edit screens; only group *scoping* endpoints were confirmed to exist.

### 5.5 Device Management

Entirely socket-driven (no REST equivalent) on `/employee`, gate: `canViewDevice` for read, per-action permissions for writes. All "online"/"USB open" state is live-derived from socket rooms, not a persisted flag — so this screen **must** subscribe to the broadcast events below rather than poll, or state will visibly drift from reality.

- List: emit `giveDevice` → results include `isOnline`/`isUSBOpen` computed at emit time.
- Live updates — subscribe to (all broadcast to room `canViewDevice` or per-device room `employee-device-<id>`): `onlineDevice`, `deviceAllowedChanged`/`deviceSelfAllowedChanged`, `employeeToDeviceAllowedChanged`/`...SelfAllowedChanged`, `deviceTypeChanged`/`deviceSelfTypeChanged`, `deviceNameChanged`/`deviceSelfNameChanged`, `unlockedUSB`/`unlockUSB`, `deviceNotAllowed`.
- Actions: `allowDevice` (gate `canAllowDevice`), `allowEmployeeToDevice` (gate `canAllowEmployeeToDevice` — **note the server-side condition on this handler is inverted/buggy per the code audit**, confirm actual behavior in a dev environment before shipping the corresponding button, it may currently behave opposite to the permission name), `changeDeviceType` (gate `canChangeDeviceType`), `changeDeviceName` (gate `canChangeDeviceName`), `openUSB` (gate `canOpenUSB`, admin-initiated remote unlock), `requestUSB`/`unlockUSB` (self-service: employee requests their own device's USB be opened via a password check against `platformOptions.USBPassword`).
- This is also the only place a new device gets authorized for login (§4) — design the "pending devices" view (devices with `isAllowed: false`) as a first-class filter, since it's the resolution path for the "device not yet authorized" login failure.

### 5.6 Attendance & Breaks

- Self view: emit `attendance` with `{ date }` → `{ attendance, breaks }` for that day. Emit `checkForBreak` → `{ break: boolean }` for current break state.
- Break toggle: emit `employeeBreak` (no payload; toggles based on server-tracked `client.attendanceId`/`client.breakId`) → listen `break-start-success`/`break-start-error`/`break-end-success`/`break-end-error`.
- Check-in/out is **implicit**, not a user action: `EmployeeAttandence.checkIn` is set on socket `login`, `checkOut` is set on `handleDisconnect`. This means the "attendance" record is really a proxy for "was this employee's dashboard socket connected," not an explicit clock-in/out — a flaky connection (laptop sleep, network drop) will register as a checkout. Design the attendance screen's language and any admin-facing attendance report around this caveat (e.g., show connection-based attendance distinctly from "official" hours if that distinction matters to the business), and confirm with stakeholders whether this proxy is acceptable before treating it as payroll-grade data.
- No admin-facing "all employees' attendance today" endpoint was found in the audited surface (only self, via `client.employeeId`) — if an admin roll-up view is needed, confirm the backend endpoint exists or needs to be added.

## 6. Cross-cutting frontend requirements

- **Realtime-first, not poll-first**: nearly every screen above (directory presence, device state, attendance-via-connection) is only correct if the client is subscribed to the relevant broadcast events. A page that only fetches once on mount will show stale state within seconds in a multi-admin environment.
- **Permission-driven rendering**: fetch `employeepermissions` (socket) / `GET /command/permissions` (REST) once per session and drive all conditional UI from it; don't infer capability from whether a button "seems safe."
- **Two independent connections to reason about in error/loading states**: REST call failures (expired JWT, 401) and socket disconnects (dropped `/employee` connection) are separate failure modes needing separate recovery UI — a valid JWT does not imply the socket is authenticated, and vice versa.
- **Write-then-broadcast pattern**: most mutating socket actions (device allow, permission change, etc.) don't return a direct ack payload to the caller beyond the broadcast event — design components to update from the subscribed broadcast event, not from an assumed synchronous response shape, and confirm actual ack behavior per event during implementation.

## 7. Backend gaps blocking or affecting this PRD

These were found during the audit and should be resolved or explicitly accepted before/while building the corresponding screen:

1. **No `/command/refresh` endpoint** — session can't be silently renewed; affects §4 session design.
2. **`POST /command/logout` unimplemented** (throws) — logout must be handled fully client-side.
3. **`GET /command/employee` (self profile) unimplemented** (throws) — profile screen must be built from `loginsuccess`/`employeeDetails` payloads instead.
4. **Plaintext password storage/comparison** — both socket and REST login compare passwords in plaintext; not a frontend concern to fix, but relevant to any "change password" UI design (no hashing migration path visible) and worth flagging to backend as a security item.
5. **No "disable employee" endpoint** exists despite `canDisableEmployee` being catalogued in `permissionsStrings.txt` — an employee-directory "deactivate" action cannot be built until this is added.
6. **`addEmployee` gate string (`EmployeeAdd`) doesn't match the documented permission name (`canAddEmployee`)** — confirm the real gate before shipping, since building against the wrong string will silently misbehave for admins who have one but not the other.
7. **Permission/group platform-course scoping is UI-only today** — the assignment endpoints exist but `checkPermission`/room-based checks ignore scope entirely; every "scoped" grant is enforced as global. Label accordingly in-product (§5.4) or hold the scoping UI until backend enforcement lands.
8. **`allowEmployeeToDevice` gate condition appears inverted in the source** — verify actual runtime behavior in a dev environment before wiring the corresponding admin control.
9. **No onboarding endpoints for `EmployeeWork`/`EmployeePersonal`, no credential-delivery step** — full onboarding requires backend additions or an accepted manual process (§5.2).
10. **No admin-facing attendance roll-up endpoint found** — only self-attendance is available; confirm before scoping an admin attendance dashboard.

## 8. Suggested delivery order

1. Session module (§4) — both transports, device-not-authorized state, single-session-conflict handling.
2. Employee Directory + presence (§5.1) — lowest risk, validates the realtime subscription pattern reused everywhere else.
3. Device Management (§5.5) — needed to unblock new-device login for any real users, so should land early despite being a "secondary" feature.
4. Org Hierarchy (§5.3) + Permissions (§5.4) — pure REST, can be built in parallel with device management.
5. Onboarding wizard (§5.2) — depends on hierarchy + permissions screens existing to chain into, and on a decision about gap #9.
6. Attendance (§5.6) — lowest priority; mostly read-only and dependent on stakeholder sign-off on the connection-proxy caveat.
