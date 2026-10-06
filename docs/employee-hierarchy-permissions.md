# Employee Hierarchy & Permission Management

> **Extension:** permissions can now also be scoped to a specific platform
> and/or course. See [employee-permission-scoping.md](employee-permission-scoping.md)
> for the new schema and endpoints — everything below is unchanged and still
> describes the default (global) behaviour.

## Overview

Two related features that work together:

1. **Hierarchy Management** — employees can view and rearrange the org chart below them. An employee can be placed under multiple managers (many-to-many). An employee can only manage people within their own subtree.

2. **Permission Assignment** — employees with the `canGivePermission` permission can assign permissions to employees below them. They can only give permissions they themselves have. When a permission is assigned, all ancestor permissions in the tree are auto-added.

Both features share the same "who is below me" traversal logic.

---

## Existing Schema (no new tables needed)

### `EmployeeToEmployee`
```prisma
model EmployeeToEmployee {
  upperEmployeeId Int
  lowerEmployeeId Int
  order           Int?
  createdAt       DateTime
  updatedAt       DateTime
  Employee        Employee @relation(fields: [upperEmployeeId], references: [id])
  Employee_1      Employee @relation("EmployeeToEmployee", fields: [lowerEmployeeId], references: [id])

  @@id([upperEmployeeId, lowerEmployeeId])
}
```
- One row = "lowerEmployee reports to upperEmployee"
- An employee can have multiple `upperEmployeeId` rows (reports to multiple managers)
- An employee can have multiple `lowerEmployeeId` rows (manages multiple people)

### `EmployeePermission` (self-referential tree)
```
id    name                         parentId
───────────────────────────────────────────
1     canViewSelf                  (none)
2     canViewProfile               1
4     canViewTech                  (none)
5     canViewDevice                4
12    canViewClasses               (none)
13    canViewLeads                 15
14    canInteractLead              12
15    canViewEnquiry               12
...
```
`permissionId` points to the parent permission. Giving a child permission automatically adds all ancestors up to the root.

### `EmployeeToEmployeePermission`
Direct employee ↔ permission assignment. Already exists — we write to this table.

### `EmployeePermissionGroup` / `EmployeePermissionGroupToEmployee`
Named permission groups assigned to employees. Read-only for this feature — we do not modify groups.

---

## New Permission to Seed

Add to `EmployeePermission` table (data, not schema):
```
name: "canGivePermission"
parentId: null   (top-level, standalone permission)
```

This permission gates the entire Permission Assignment feature. Only employees who have it can assign permissions to others.

---

## Feature 1: Employee Hierarchy Management

### Rules
- An employee can only view/manage employees in their own subtree (direct and indirect reports, infinitely deep)
- An employee can place any subtree employee under any other subtree employee
- An employee can be under multiple managers simultaneously (many-to-many is already supported by the schema)
- An employee cannot place someone above themselves or outside their subtree

### "Subtree" Algorithm
```
getSubtree(employeeId):
  result = []
  queue = [employeeId]
  visited = Set()
  while queue not empty:
    current = queue.pop()
    direct_reports = EmployeeToEmployee.findMany where upperEmployeeId = current
    for each report:
      if report.lowerEmployeeId not in visited:
        visited.add(report.lowerEmployeeId)
        result.push(report.lowerEmployeeId)
        queue.push(report.lowerEmployeeId)
  return result  // all employee IDs below the caller
```

Cycles are prevented by the `visited` set.

---

### API Endpoints

#### `GET /command/hierarchy/tree`
Returns the full hierarchy tree below the logged-in employee, as a nested structure.

**Response:**
```json
{
  "id": 5,
  "fname": "Priya",
  "lname": "Singh",
  "designation": "Manager",
  "children": [
    {
      "id": 8,
      "fname": "Vikram",
      "lname": "Kumar",
      "designation": "Senior Executive",
      "children": [
        { "id": 12, "fname": "Arun", "lname": "Mehta", "designation": "Executive", "children": [] }
      ]
    },
    {
      "id": 9,
      "fname": "Sneha",
      "lname": "Patel",
      "designation": "Executive",
      "children": []
    }
  ]
}
```

Note: if an employee appears under multiple managers, they appear in each parent's `children` array.

---

#### `GET /command/hierarchy/flat`
Returns the same subtree as a flat list (useful for dropdowns/search when selecting employees).

**Response:**
```json
[
  { "id": 8, "fname": "Vikram", "lname": "Kumar", "designation": "Senior Executive" },
  { "id": 9, "fname": "Sneha", "lname": "Patel", "designation": "Executive" },
  { "id": 12, "fname": "Arun", "lname": "Mehta", "designation": "Executive" }
]
```

---

#### `POST /command/hierarchy/assign`
Place `lowerEmployeeId` under `upperEmployeeId`. Both must be within the caller's subtree. The `upperEmployeeId` may also be the caller themselves.

**Body:**
```json
{
  "upperEmployeeId": 8,
  "lowerEmployeeId": 12
}
```

**Validations:**
- `lowerEmployeeId` must be in caller's subtree
- `upperEmployeeId` must be the caller OR in caller's subtree
- `upperEmployeeId !== lowerEmployeeId`
- The pair must not already exist (deduplication)
- `lowerEmployeeId` must not be an ancestor of `upperEmployeeId` (would create a cycle)

---

#### `DELETE /command/hierarchy/remove`
Remove the reporting relationship between two employees. Both must be in caller's subtree.

**Body:**
```json
{
  "upperEmployeeId": 8,
  "lowerEmployeeId": 12
}
```

**Validations:**
- Both employees must be in caller's subtree
- The relationship must exist
- After removal, `lowerEmployeeId` must still have at least one manager (cannot be left floating with no parent unless they become a direct report of the caller)

---

#### `POST /command/hierarchy/move`
Atomically move `lowerEmployeeId` under a new manager (`newUpperEmployeeId`), removing **all** their current reporting relationships in the process. This is the drag-and-drop endpoint — it replaces, not appends.

**Body:**
```json
{
  "lowerEmployeeId": 12,
  "newUpperEmployeeId": 9
}
```

**What it does internally:**
1. Verifies `lowerEmployeeId` is in caller's subtree
2. Verifies `newUpperEmployeeId` is the caller or in caller's subtree
3. Verifies no cycle would be created
4. Deletes all existing `EmployeeToEmployee` rows where `lowerEmployeeId = <moved employee>`
5. Inserts one new row: `upperEmployeeId = newUpperEmployeeId, lowerEmployeeId = <moved employee>`

**Validations:**
- `lowerEmployeeId` must be in caller's subtree
- `newUpperEmployeeId` must be the caller OR in caller's subtree
- `newUpperEmployeeId !== lowerEmployeeId`
- `lowerEmployeeId` must not be an ancestor of `newUpperEmployeeId` (cycle check)

**Response:**
```json
{
  "movedEmployeeId": 12,
  "newUpperEmployeeId": 9,
  "removedRelationships": [
    { "upperEmployeeId": 8, "lowerEmployeeId": 12 }
  ]
}
```

---

## Feature 2: Permission Assignment

### Rules
- Caller must have `canGivePermission` permission
- Caller can only assign permissions to employees in their subtree
- Caller can only assign permissions they themselves have
- When assigning permission X (which has parent Y → Z): X, Y, and Z are all added automatically
- Caller must have all of X, Y, Z themselves before they can assign X
- Caller can revoke a permission they previously assigned (only if the target is still in their subtree)
- Caller cannot revoke permissions that were assigned by someone else (permissions come from multiple sources — direct assignment, group membership)

### Parent Permission Chain Algorithm
```
getPermissionChain(permissionId):
  chain = [permissionId]
  current = EmployeePermission.findById(permissionId)
  while current.permissionId != null:
    chain.push(current.permissionId)
    current = EmployeePermission.findById(current.permissionId)
  return chain  // [child, parent, grandparent, ...]
```

Example: assigning `canViewLeads` (id=13, parent=15) → chain = [13, 15, 12] → assigns `canViewLeads` + `canViewEnquiry` + `canViewClasses`.

### "What can I give?" Algorithm
```
getGrantablePermissions(employeeId):
  myPermissions = all permissions the caller has (via direct assignment + groups)
  for each permission in myPermissions:
    // only include permissions where the full chain is within myPermissions
    // (can't give canViewLeads if you don't have canViewEnquiry and canViewClasses)
    chain = getPermissionChain(permission.id)
    if all ids in chain are in myPermissions:
      include this permission
  return filtered list
```

---

### API Endpoints

#### `GET /command/permissions/grantable`
Returns all permissions the caller is eligible to grant (they have it + full parent chain covered).

**Response:**
```json
[
  { "id": 13, "name": "canViewLeads", "parentId": 15, "autoAdds": ["canViewEnquiry", "canViewClasses"] },
  { "id": 14, "name": "canInteractLead", "parentId": 12, "autoAdds": ["canViewClasses"] }
]
```

`autoAdds` tells the frontend which extra permissions will be silently added.

---

#### `GET /command/permissions/employee/:employeeId`
Returns all permissions a specific employee below the caller currently has.

**Response:**
```json
{
  "employeeId": 8,
  "fname": "Vikram",
  "permissions": [
    { "id": 12, "name": "canViewClasses", "source": "direct" },
    { "id": 15, "name": "canViewEnquiry", "source": "direct" },
    { "id": 13, "name": "canViewLeads", "source": "direct" }
  ]
}
```

`source` can be `direct` (from `EmployeeToEmployeePermission`) or `group` (from `EmployeePermissionGroup`).

---

#### `POST /command/permissions/assign`
Assign a permission to an employee below the caller. Auto-adds the full parent chain.

**Body:**
```json
{
  "employeeId": 8,
  "permissionId": 13
}
```

**Validations:**
- Caller has `canGivePermission`
- `employeeId` is in caller's subtree
- Caller has permissionId AND all its ancestors
- Skips permissions the target already has (idempotent)

**Response:**
```json
{
  "assigned": [
    { "id": 13, "name": "canViewLeads" },
    { "id": 15, "name": "canViewEnquiry" },
    { "id": 12, "name": "canViewClasses" }
  ],
  "alreadyHad": []
}
```

---

#### `DELETE /command/permissions/revoke`
Revoke a directly-assigned permission from an employee below the caller.

**Body:**
```json
{
  "employeeId": 8,
  "permissionId": 13
}
```

**Validations:**
- Caller has `canGivePermission`
- `employeeId` is in caller's subtree
- The permission was directly assigned (not from a group — groups are not touched)
- Does NOT auto-remove parent permissions (parents may be needed for other child permissions the employee still has)

---

## Where Code Lives

| What | File |
|---|---|
| Service | `src/command/command.hierarchy.service.ts` (new) |
| Controller routes | `src/command/command.controller.ts` (appended) |
| Module registration | `src/command/command.module.ts` |

New endpoints added by this feature:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/command/hierarchy/tree` | Nested tree below caller |
| `GET` | `/command/hierarchy/flat` | Flat list below caller |
| `POST` | `/command/hierarchy/assign` | Add a reporting relationship (additive) |
| `POST` | `/command/hierarchy/move` | Move employee to new manager (replaces all old relationships) |
| `DELETE` | `/command/hierarchy/remove` | Remove one reporting relationship |

No schema changes. No new tables. No migration needed.

---

## Edge Cases

### Hierarchy

| Case | Behaviour |
|---|---|
| Assigning A under B, but B is already under A | `400` — would create a cycle |
| Employee already under that manager (assign) | `400` — relationship already exists |
| Removing the only manager of an employee | `400` — employee would become unreachable (must have at least one upper employee) |
| Moving the only manager of an employee (move) | Allowed — move replaces all old relationships; the employee ends up with exactly one new manager |
| Employee not in caller's subtree | `403 Forbidden` |
| Caller tries to place someone above themselves | `403 Forbidden` |

### Permissions

| Case | Behaviour |
|---|---|
| Caller tries to give a permission they don't have | `403 Forbidden` |
| Caller tries to give a permission whose parent chain they don't fully have | `403 Forbidden` |
| Target already has the permission | Silently skipped, still returns success |
| Target has permission via a group, caller tries to revoke | `400` — can only revoke direct assignments |
| Caller without `canGivePermission` hits any permission endpoint | `403 Forbidden` |
| Target employee not in caller's subtree | `403 Forbidden` |

---

## Frontend Instructions

### 1. On Login — Fetch Caller's Own State

Immediately after employee login, fetch two things and store in global app state:

```
GET /command/hierarchy/flat     → store as mySubtree (list of employee IDs below me)
GET /command/permissions/grantable → store as grantablePermissions (what I can assign)
```

Also check if the employee has `canGivePermission` in their own permission list. Store this as a boolean flag (`canManagePermissions`). Use it to conditionally show/hide the Permissions tab throughout the app.

---

### 2. Where These Features Live

Both features live under an **"Org Chart"** section in the command panel sidebar.

```
Sidebar
├── Dashboard
├── Leads
├── Users
├── Org Chart       ← here
│     ├── Tree View
│     └── [Employee Detail Panel — opens on click]
└── Settings
```

---

### 3. Tree View

#### Loading
Call `GET /command/hierarchy/tree` on mount. Show a loading skeleton while fetching.

#### Rendering the Org Chart
Render as an interactive tree diagram (vertical top-down layout):

```
              ┌──────────────┐
              │  Priya Singh │  ← logged-in employee (root)
              │   Manager    │
              └──────┬───────┘
           ┌─────────┴──────────┐
    ┌──────┴──────┐      ┌──────┴──────┐
    │ Vikram Kumar│      │ Sneha Patel │
    │Sr. Executive│      │  Executive  │
    └──────┬──────┘      └─────────────┘
    ┌──────┴──────┐
    │  Arun Mehta │
    │  Executive  │
    └─────────────┘
```

Each node shows:
- Profile photo (circular, fallback to initials)
- Full name
- Designation (from `EmployeeWork.designation`)
- A subtle indicator if they report to multiple managers (e.g. a double-border or "2 managers" label)

Lines between nodes are the reporting relationships. If an employee appears under multiple parents, draw a line from each parent to them (converging lines are expected).

#### Interactions on a node
- **Single click** → open Employee Detail Panel (slide-in from right)
- **Drag** → initiate drag-to-assign (see section 5)

#### Zoom and pan
Support mouse-wheel zoom and drag-to-pan on the canvas. The root (logged-in employee) should be centered on initial load.

#### Refresh
After any assign or remove operation, re-fetch `GET /command/hierarchy/tree` and re-render the chart. Do not try to patch the local tree — always fetch fresh.

---

### 4. Employee Detail Panel

Opens as a right-side drawer when clicking any node. Contains two tabs:

```
┌─────────────────────────────────┐
│  [Photo]  Vikram Kumar          │
│           Sr. Executive         │
│           vikram@example.com    │
├──────────────────────────────────
│  [ Hierarchy ]  [ Permissions ] │  ← Permissions tab only if canManagePermissions = true
├──────────────────────────────────
│  (tab content)                  │
└─────────────────────────────────┘
```

#### Hierarchy Tab (default)

Shows two sections:

**Reports to** (managers of this employee):
- List of employees who are above this employee
- Each has a "Remove relationship" button
- On click: confirm dialog → `DELETE /command/hierarchy/remove` with `{ upperEmployeeId: manager.id, lowerEmployeeId: employee.id }`
- If this is the employee's only manager, disable the button with tooltip: "Must have at least one manager"

**Direct reports** (employees below this employee):
- List of employees who directly report to this employee
- Each has a "Remove relationship" button (same as above but reversed)

**Add a manager** button:
- Opens a searchable dropdown populated from `GET /command/hierarchy/flat`
- Filter out employees who are already a manager of this employee
- On select: `POST /command/hierarchy/assign` with `{ upperEmployeeId: selected, lowerEmployeeId: employee.id }`

---

#### Permissions Tab (only if `canManagePermissions = true`)

Call `GET /command/permissions/employee/:employeeId` when this tab is opened.

**Display two sections:**

**Direct Permissions** (`source: "direct"`):
```
┌──────────────────────────────────────────┐
│ ● canViewClasses                 [Revoke]│
│ ● canViewEnquiry                 [Revoke]│
│ ● canViewLeads                   [Revoke]│
└──────────────────────────────────────────┘
```
- Each permission shows its name
- Revoke button → confirm dialog → `DELETE /command/permissions/revoke`
- Only show Revoke if the caller has this permission in their own `grantablePermissions` list (can't revoke what you couldn't have given)

**Via Group** (`source: "group"`):
```
┌──────────────────────────────────────────┐
│ ○ canViewPlatform      [via Sales Group] │
│ ○ canViewTech          [via Sales Group] │
└──────────────────────────────────────────┘
```
- Greyed out, no revoke button
- Tooltip on hover: "Assigned via group — manage groups separately"

**Assign Permission button:**

Opens a modal:
```
┌──────────────────────────────────────────┐
│  Assign Permission to Vikram             │
│                                          │
│  Select permission:                      │
│  [ Search permissions...           ▼ ]  │
│                                          │
│  ⚠ This will also add:                  │
│    · canViewEnquiry                      │
│    · canViewClasses                      │
│                                          │
│  [Cancel]              [Assign]          │
└──────────────────────────────────────────┘
```

- Dropdown is populated from `grantablePermissions` (cached from login)
- Filter out permissions the employee already has
- On permission select: compute `autoAdds` from the `autoAdds` field in the grantable response and show the warning block
- On Assign: `POST /command/permissions/assign` → refresh permissions list
- Show success toast: "canViewLeads and 2 other permissions assigned to Vikram"

---

### 5. Drag to Move (Hierarchy Rearranging)

Drag-and-drop is a **move** operation: the dragged employee is removed from all current managers and placed exclusively under the drop target. This is the primary way to rearrange the org chart.

**What it means:** "Make the dragged employee report only to the employee they were dropped onto"

#### Visual cues during drag

```
              ┌──────────────┐
              │  Priya Singh │  (root, valid drop target — outlined in blue)
              └──────┬───────┘
           ┌─────────┴────────────────┐
    ┌──────┴──────┐            ┌──────┴──────┐
    │ Vikram Kumar│  ← DRAGGING│ Sneha Patel │  (valid — outlined in blue)
    │ ░░░░░░░░░░ │             └─────────────┘
    └─────────────┘
    ┌──────┴──────┐
    │  Arun Mehta │  ← dragged node (semi-transparent while dragging)
    │  Executive  │
    └─────────────┘
```

- **Dragging node**: rendered semi-transparent (opacity 50%) in its original position
- **Valid drop targets**: all nodes in `mySubtree` + the logged-in employee's own node — highlight with a blue ring/border
- **Invalid drop targets**: the dragged node itself, and any employees outside the caller's subtree — dimmed/greyed, no drop indicator
- **Hovering over a valid target**: show a filled blue highlight and a "drop here" indicator (e.g. arrow or shadow)

#### On drop

1. Call `POST /command/hierarchy/move`:
   ```json
   { "lowerEmployeeId": <draggedId>, "newUpperEmployeeId": <droppedOntoId> }
   ```
2. Show a confirmation toast:
   > "Arun Mehta moved under Sneha Patel. Previous reporting relationships removed."
3. Refresh the tree (`GET /command/hierarchy/tree`)

#### On error

| Error | Toast |
|-------|-------|
| `400` — would create cycle | "Cannot move — this would create a circular reporting chain" |
| `400` — same employee | "Cannot place an employee under themselves" |
| `403` — not in subtree | "You can only manage employees in your team" |

#### Important behaviour differences

| Action | Endpoint | Old relationships |
|--------|----------|------------------|
| **Drag & drop** | `POST /command/hierarchy/move` | **Removed** — employee now reports only to new manager |
| **Add manager** (detail panel) | `POST /command/hierarchy/assign` | **Kept** — employee reports to both old and new manager |

Use drag-and-drop when you want to reassign someone entirely. Use "Add manager" in the detail panel when you want someone to report to multiple managers simultaneously.

---

### 6. Manual Assign via Flat List

Alternative to drag-and-drop for when the tree is deep and hard to navigate:

- A "Assign Reporting Relationship" button above the tree
- Opens a modal with two searchable dropdowns:
  ```
  Who reports to whom?
  [ Search employee (lower) ▼ ]  reports to  [ Search employee (upper) ▼ ]
  [Assign]
  ```
- Both dropdowns are populated from `GET /command/hierarchy/flat`
- On submit: `POST /command/hierarchy/assign`

---

### 7. Error Handling

| API Error | UI Response |
|-----------|-------------|
| `400` — relationship already exists | Toast: "This reporting relationship already exists" |
| `400` — would create a cycle (assign or move) | Toast: "Cannot assign — creates a circular reporting chain" |
| `400` — last manager (remove only) | Toast: "Cannot remove — employee must have at least one manager" |
| `403` — employee not in subtree | Toast: "You can only manage employees in your team" |
| `403` — permission not grantable | Toast: "You don't have this permission to give" |
| `403` — canGivePermission missing | Hide the feature entirely (checked on login) |

---

### 8. State Management Tips

- Cache `mySubtree` (flat list) from login — refresh only when hierarchy changes
- Cache `grantablePermissions` from login — refresh only when caller's own permissions change
- Do NOT cache the tree response — always fetch fresh after mutations
- Store `canManagePermissions` boolean in global auth state — used in multiple places to show/hide tabs and buttons

---

### 9. Flow Summary

```
Login
  ↓
GET /command/hierarchy/flat → cache mySubtree
GET /command/permissions/grantable → cache grantablePermissions
Check canGivePermission → cache canManagePermissions flag
  ↓
Open Org Chart
  ↓
GET /command/hierarchy/tree → render tree
  ↓
  ├─ Drag node → drop on another node (MOVE)
  │    → POST /command/hierarchy/move → refresh tree
  │
  ├─ Click node → Employee Detail Panel
  │    ↓
  │    Hierarchy tab (default)
  │      ├─ Add manager → flat list dropdown → POST /command/hierarchy/assign
  │      └─ Remove relationship → confirm → DELETE /command/hierarchy/remove
  │    ↓
  │    Permissions tab (only if canManagePermissions)
  │      ├─ GET /command/permissions/employee/:id → show direct + group permissions
  │      ├─ Assign → select from grantablePermissions → preview autoAdds → POST /command/permissions/assign
  │      └─ Revoke → confirm → DELETE /command/permissions/revoke
  │
  └─ "Assign Relationship" button → manual modal → POST /command/hierarchy/assign
```
