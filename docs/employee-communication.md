# Employee Communication

## Overview

A chat system for employees accessible via the command module. Employees can create group chats, direct message each other, and — with special permission — view and message into user-side chat rooms. All real-time events run over the existing `/employee` Socket.IO namespace.

---

## Pre-existing Schema (no new tables needed for these)

| Model | Relevance |
|---|---|
| `ChatRoom` | Shared room model; `type` distinguishes Group / Desk / lead / Course etc. |
| `ChatroomToEmployees` | Employee membership in a room — has `isAdmin` field |
| `ChatRoomMessage` | Already has `employeeId` — employees can be message senders |
| `ChatMessageView` | Already has `employeeId` — employee read receipts |
| `ChatRoomPinnedToEmployee` | Employees can pin rooms |
| `ChatRoomMessagePinToEmployee` | Employees can pin messages |
| `ChatRoomToLead` | Links a chat room to a lead |

### `ChatRoomType` enum (existing values)
`Friend | Group | Broadcast | Course | Desk | Platform | lead`

- Employee groups use `Group`
- Employee DMs use `Desk`
- User-side rooms use `Course`, `lead`, `Platform`, `Friend`

---

## Schema Change — 1 field

`isAdmin` on `ChatroomToEmployees`:

```prisma
model ChatroomToEmployees {
  id         Int      @id @default(autoincrement())
  employeeId Int
  chatroomId Int
  isAdmin    Boolean  @default(false)
  Employee   Employee @relation(fields: [employeeId], references: [id])
  ChatRoom   ChatRoom @relation(fields: [chatroomId], references: [id])
}
```

The employee who creates a group is automatically set as admin. Admins can add/remove members and update group info.

---

## API Endpoints

All endpoints use `EmployeeAuthGuard`. All are prefixed `/command/chat`.

### My Rooms

#### `GET /command/chat/rooms`
Returns all chat rooms the employee is a member of, sorted by latest message descending.

**Response:**
```json
[
  {
    "id": 1,
    "name": "Sales Team",
    "icon": null,
    "description": null,
    "type": "Group",
    "isPinned": false,
    "isAdmin": true,
    "members": [
      { "id": 2, "fname": "John", "lname": "Doe", "profile": "..." }
    ],
    "lastMessage": {
      "message": "Meeting at 3pm",
      "employeeId": 5,
      "userId": null,
      "createdAt": "2026-06-17T10:00:00Z",
      "employee": { "id": 5, "fname": "Jane", "lname": "Smith", "profile": "..." },
      "user": null
    }
  }
]
```

**Notes:**
- `members` is a flat array of `Employee` objects (id, fname, lname, profile)
- `isAdmin` reflects whether the requesting employee is admin in this room
- No `unreadCount` is returned here — track unread client-side from socket events

---

#### `GET /command/chat/room/:roomId/messages?page=1`
Returns paginated messages for a room (50 per page, page is 1-based). Employee must be a member.

**Response:**
```json
{
  "messages": [
    {
      "id": 101,
      "message": "Hello team",
      "employeeId": 5,
      "userId": null,
      "attachment": { "link": "https://...", "type": "image" },
      "type": null,
      "createdAt": "2026-06-17T10:00:00Z",
      "Employee": { "id": 5, "fname": "Jane", "lname": "Smith", "profile": "..." },
      "User": null,
      "ParentMessage": null,
      "Reactions": [],
      "isPinned": false,
      "isViewed": true,
      "EmployeePinned": [],
      "Views": []
    }
  ],
  "page": 1,
  "hasMore": true
}
```

---

#### `GET /command/chat/room/:roomId/gallery?page=1`
Returns paginated messages that have attachments (10 per page).

**Response:** `{ messages, total }`

---

### Groups

#### `POST /command/chat/group`
Create a new group chat. The creator is automatically added as admin.

**Body:**
```json
{
  "name": "Sales Team",
  "icon": "https://...",
  "description": "Internal sales coordination",
  "employeeIds": [2, 3, 4]
}
```

**Response:** Created `ChatRoom` with raw `Employees` join-table array:
```json
{
  "id": 1,
  "name": "Sales Team",
  "icon": null,
  "type": "Group",
  "Employees": [
    { "id": 1, "employeeId": 1, "chatroomId": 1, "isAdmin": true, "Employee": { "id": 1, "fname": "John", "lname": "Doe", "profile": "..." } },
    { "id": 2, "employeeId": 2, "chatroomId": 1, "isAdmin": false, "Employee": { "id": 2, "fname": "Jane", "lname": "Smith", "profile": "..." } }
  ]
}
```

---

#### `PATCH /command/chat/group/:roomId`
Update group name, icon, or description. Admin only.

**Body:**
```json
{
  "name": "Sales & Support",
  "icon": "https://...",
  "description": "Updated description"
}
```

---

#### `POST /command/chat/group/:roomId/members`
Add one or more employees to a group. Admin only.

**Body:**
```json
{ "employeeIds": [6, 7] }
```

**Response:** `{ "message": "Members added", "members": [...] }`

---

#### `DELETE /command/chat/group/:roomId/members/:employeeId`
Remove an employee from the group. Admin only. Admin cannot remove themselves — use leave instead.

**Response:** `{ "message": "Member removed" }`

---

#### `DELETE /command/chat/group/:roomId/leave`
Leave a group. If the leaving employee is the only admin, the next member (by join date) is promoted to admin automatically. If no members remain after leaving, the room is soft-deleted.

**Response:** `{ "message": "Left group" }`

---

### DMs

#### `GET /command/chat/dm/:employeeId`
Get an existing DM room with the target employee, or create one if it doesn't exist. Uses `ChatRoomType = Desk`. Returns `400` for self-DM.

**Response:** Raw `ChatRoom` with `Employees` join-table array (same shape as group create response).

---

### Messaging

#### `POST /command/chat/message`
Send a message to any room the employee is a member of. Supports file upload (`multipart/form-data`).

**Body fields:**
```json
{
  "roomId": 1,
  "message": "Hello team",
  "replyToId": null,
  "attachment": null,
  "userIds": [],
  "employeeIds": [],
  "pollQuestion": null,
  "pollOptions": [],
  "isPollMultiSelect": false,
  "lectureIds": [],
  "doubtIds": [],
  "practiceIds": [],
  "mockIds": []
}
```

All fields except `roomId` are optional. Emits `new_message` to `chat_room_${roomId}` on `/employee`.

**Response:** Full message object with `isPinned`, `isViewed`, `Employee`, `User`, `ParentMessage`, `Reactions`.

---

#### `POST /command/chat/poll/:messageId`
Vote on a poll option (toggle — voting the same option again removes the vote).

**Body:** `{ "selectedOption": <optionId> }`

Emits `poll_voted` or `poll_vote_deleted` socket event.

**Response:** `{ "voted": true/false }`

---

#### `PATCH /command/chat/message/:messageId`
Edit a message. Employee can only edit their own messages.

**Body:** `{ "newContent": "Updated message" }`

Emits `message_edited` via socket.

---

#### `DELETE /command/chat/message/:messageId`
Soft-delete a message (`isVisible = false`). Employee can only delete their own messages.

Emits `message_deleted` via socket.

**Response:** `{ "message": "Deleted" }`

---

#### `POST /command/chat/react`
Add or toggle a reaction on a message.

**Body:**
```json
{ "messageId": 101, "reaction": "👍" }
```

---

#### `POST /command/chat/pin/message/:messageId`
Pin or unpin a message for this employee (toggle). Stored in `ChatRoomMessagePinToEmployee`.

**Response:** `{ "pinned": true/false }`

---

#### `POST /command/chat/view/:messageId`
Mark a single message as viewed. Creates a `ChatMessageView` record with `employeeId`.

**Response:** `{ "viewed": true }`

---

#### `POST /command/chat/viewall/:roomId`
Mark all unviewed messages in a room as viewed.

**Response:** `{ "viewed": <count> }`

---

#### `GET /command/chat/typing/:roomId?status=true`
Broadcast typing indicator to other members of the room. Emits `typing` event via socket with `{ employeeId, roomId, status }`.

**Response:** `{ "ok": true }`

---

### User Rooms (Permission-gated)

These endpoints require `communicate.user.rooms` permission checked inside the service.

#### `GET /command/chat/user-rooms?courseId=&platformId=&page=`
Returns user-side chat rooms filterable by `courseId` and/or `platformId`.

**Query params (all optional):**
- `courseId` — filter by course
- `platformId` — filter by platform
- `page` — 1-based pagination

**Response:**
```json
{
  "rooms": [
    {
      "id": 50,
      "name": null,
      "type": "lead",
      "courseId": null,
      "platformId": null,
      "users": [{ "id": 12, "fname": "Rahul", "lname": "Sharma", "phone": "..." }],
      "leads": [{ "id": 3, "fname": "Rahul", "lname": "Sharma", "phone": "..." }],
      "lastMessage": { "message": "When does batch start?", "userId": 12, "employeeId": null, "Employee": null, "User": { "fname": "Rahul" } }
    }
  ],
  "page": 1,
  "hasMore": true
}
```

---

#### `POST /command/chat/user-rooms/:roomId/message`
Send a message into a user-side chat room. Requires `communicate.user.rooms` permission. The message is sent with `employeeId` so users see it came from an employee.

**Body:**
```json
{ "message": "Hi Rahul, batch starts July 1st.", "replyToId": null }
```

Emits `new_message` to the user room via `/user` namespace so users receive it.

---

## Socket Events (`/employee` namespace)

Chat socket events run on the `/employee` namespace — the same connection employees already use for leads and notifications. Do **not** use `/command` for chat.

### On Connect
When an employee connects to `/employee` (or logs in via the `login` socket event), they automatically join all their chat room socket rooms:
```
chat_room_1
chat_room_5
chat_room_12
...
```
This happens in both `handleConnection` (for token-based connections) and in the `login` handler (for connections that authenticate after connecting).

### Subscribe (client → server)

| Event | Payload | Purpose |
|---|---|---|
| `chat_typing` | `{ roomId: number, status: boolean }` | Broadcast typing indicator to room members |

### Emit (server → client)

| Event | Payload | Trigger |
|---|---|---|
| `new_message` | Full message object | When any member sends a message to a shared room |
| `message_edited` | `{ messageId, newContent, roomId }` | When a message is edited |
| `message_deleted` | `{ messageId, roomId }` | When a message is deleted |
| `typing` | `{ employeeId, roomId, status }` | When someone triggers the typing event |
| `poll_voted` | `{ messageId, optionId, roomId, employeeId }` | When an employee votes on a poll |
| `poll_vote_deleted` | `{ messageId, optionId, roomId, employeeId }` | When an employee removes their poll vote |

---

## Permission String

User rooms are gated behind:
```
communicate.user.rooms
```

Checked using `EmployePermissionCheck.checkPermission(employeeId, platformId, 'communicate.user.rooms')`.

---

## Where Code Lives

| What | File |
|---|---|
| Schema change | `prisma/schema.prisma` — `isAdmin` on `ChatroomToEmployees` |
| Service | `src/command/command.communicate.service.ts` |
| Controller routes | `src/command/command.controller.ts` (appended) |
| Socket join on connect/login | `src/employee/employee.service.ts` — `joinEmployeeChatRooms` |
| Socket event handlers | `src/employee/employee.gateway.ts` — `chat_typing` subscriber |

---

## Edge Cases

| Case | Behaviour |
|---|---|
| Employee tries to message a room they are not in | `403 Forbidden` |
| Non-admin tries to add/remove/rename a group | `403 Forbidden` |
| Admin leaves group with no other admins | Next member (earliest join) is auto-promoted to admin |
| Last member leaves group | Room is marked inactive / soft-deleted |
| DM with self | `400 Bad Request` |
| DM already exists between two employees | Returns existing room, does not create a duplicate |
| Employee without `communicate.user.rooms` permission hits user-room endpoints | `403 Forbidden` |
| Employee sends to user room — user receives it | Message emitted on `/user` namespace so student gets it in their chat |

---

## Frontend Instructions

### 1. Socket Setup

Chat events run on the `/employee` namespace — the same socket connection already used for lead notifications. Reuse the existing `/employee` socket; **do not** open a separate `/command` socket for chat.

```js
const socket = io('/employee', {
  extraHeaders: { dauth: employeeToken }
})

socket.on('new_message',       (msg)  => { /* append to room */ })
socket.on('message_edited',    (data) => { /* update message in state */ })
socket.on('message_deleted',   (data) => { /* remove message from state */ })
socket.on('typing',            (data) => { /* show typing indicator */ })
socket.on('poll_voted',        (data) => { /* update poll vote counts */ })
socket.on('poll_vote_deleted', (data) => { /* update poll vote counts */ })
```

Do not reconnect on every screen change — one socket connection per session is enough.

---

### 2. App Layout

```
┌─────────────────────────────┐
│  🔍 Search rooms / employees│
├─────────────────────────────┤
│  PINNED                     │
│  ● Sales Team               │
│  ● Rahul DM                 │
├─────────────────────────────┤
│  GROUPS                     │
│  ● Marketing Team           │
│  ● All Employees            │
├─────────────────────────────┤
│  DIRECT MESSAGES            │
│  ● Priya Singh              │
│  ● Vikram Kumar             │
├─────────────────────────────┤
│  👥 USER ROOMS  (if perm)   │
│  ● Rahul Sharma (lead)      │
│  ● Batch JEE 2025 (course)  │
└─────────────────────────────┘
```

- Unread count should be tracked client-side from `new_message` socket events
- Pinned rooms (from `isPinned` in the rooms response) float to the top section
- **User Rooms** section is only visible if the employee has `communicate.user.rooms` permission

---

### 3. Loading Rooms

On chat tab open, call `GET /command/chat/rooms`. Render each room in the sidebar.

**Room display name logic:**
- `type = Group` or `type = Broadcast` → use `room.name`
- `type = Desk` (DM) → show the other employee's name (filter `room.members` to find the non-self employee)
- `type = lead` → show lead name
- `type = Course` → show course name

**Last message preview:**
- If `lastMessage.employeeId` is self → prefix with "You: "
- If `lastMessage.userId` → show user's first name
- Truncate to 40 characters

---

### 4. Opening a Room

When a room is clicked, call `GET /command/chat/room/:roomId/messages?page=1`.

- Render messages in reverse chronological order (newest at bottom)
- Immediately call `POST /command/chat/viewall/:roomId` to reset unread count in local state
- Load more pages on scroll-to-top (increment `page`)

**Message bubble display:**
- `employeeId = self` → right-aligned, "You" label
- `employeeId != null and != self` → left-aligned, employee name label
- `userId != null` → left-aligned, user name label (only in user rooms), different bubble colour

---

### 5. Sending a Message

On send:
1. Optimistically append the message to local state with a `pending` flag
2. Call `POST /command/chat/message`
3. On success: replace the optimistic message with the server response
4. On failure: show error, keep the input text

For replies: store `replyToId` when the employee taps "Reply". Show a reply preview above the input box. Clear it on send or cancel.

For attachments: send as `multipart/form-data` with the `attachment` field.

---

### 6. Creating a Group

Open a "New Group" modal:
1. Enter group name (required), icon (optional), description (optional)
2. Search and select employees to add
3. On submit: call `POST /command/chat/group`
4. On success: prepend the new room to the sidebar and open it immediately

The response has `Employees` (raw join-table) — map `room.Employees.map(e => e.Employee)` to display member list.

---

### 7. Group Management (admin only)

Show a group settings panel. Only render management controls if `room.isAdmin = true` for the current employee (from the rooms list response).

**Controls:**
- Edit name / icon / description → `PATCH /command/chat/group/:roomId`
- Add members → search + select → `POST /command/chat/group/:roomId/members`
- Remove member → confirm dialog → `DELETE /command/chat/group/:roomId/members/:employeeId`
- Leave group → confirm dialog → `DELETE /command/chat/group/:roomId/leave`

Non-admins only see the member list and the Leave option.

---

### 8. Direct Messages

On clicking another employee's profile, offer a "Message" button. Call `GET /command/chat/dm/:employeeId` — this creates the room if needed and returns it. Navigate to that room immediately.

The response has `Employees` array (raw join-table) — same shape as group create.

---

### 9. Typing Indicator

When the employee starts typing:
```js
socket.emit('chat_typing', { roomId, status: true })
```

When they stop (debounce 2 seconds):
```js
socket.emit('chat_typing', { roomId, status: false })
```

Show "Name is typing..." indicator when `typing` event arrives with `status: true` from another employee in the same room. Hide after 3 seconds or when `status: false` arrives.

---

### 10. Reactions

On long-press or hover of a message, show an emoji picker. On select:
- Call `POST /command/chat/react` with `{ messageId, reaction }`
- If the same reaction already exists from this employee, it is toggled off (backend handles this)
- Update reaction counts in local state

---

### 11. Polls

To send a poll:
- Include `pollQuestion`, `pollOptions[]`, and optionally `isPollMultiSelect` in the `POST /command/chat/message` body

To vote:
- Call `POST /command/chat/poll/:messageId` with `{ selectedOption: <optionId> }`
- On `poll_voted` socket event: increment that option's count in local state
- On `poll_vote_deleted` socket event: decrement that option's count

---

### 12. Pinning

**Pin a message:** long-press a message → "Pin". Call `POST /command/chat/pin/message/:messageId`. Show pinned messages in a collapsible "Pinned" bar at the top of the chat window.

---

### 13. User Rooms Section

Only shown to employees with `communicate.user.rooms` permission.

**Loading:** Call `GET /command/chat/user-rooms` with optional `courseId` and `platformId` filters. Show a filter bar at the top of this section.

**Room types:**
- `lead` rooms → show `room.leads[0].fname + lname` + phone
- `Course` rooms → show course name + enrolled user count
- `Platform` rooms → show platform name

**Sending a message into a user room:**
- Uses `POST /command/chat/user-rooms/:roomId/message`
- The message appears in the user's chat as coming from an employee (different bubble colour on the user's end)

---

### 14. Media Gallery

Call `GET /command/chat/room/:roomId/gallery?page=1` to load all shared images/files in a room. Show in a grid under a "Media" tab in the room info panel.

---

### 15. Unread Count Badge

Track unread client-side:
- On `new_message` socket event: if `roomId` is not the currently open room → increment that room's badge in local state
- If it IS the currently open room → call `POST /command/chat/view/:messageId` immediately and do not increment the badge
- When opening a room → call `POST /command/chat/viewall/:roomId` and reset badge to 0

---

### 16. Flow Summary

```
Login
  ↓
Connect socket /employee  (reuse for chat — same connection as leads/notifications)
  ↓
Open Chat tab → GET /command/chat/rooms
  ↓
Click room → GET /command/chat/room/:id/messages + POST /command/chat/viewall/:id
  ↓
Send message → POST /command/chat/message
  ↓
Receive message → socket new_message event → append to room

User Rooms (if permitted):
GET /command/chat/user-rooms → filter by course/platform → open room → POST /command/chat/user-rooms/:id/message

Media:
GET /command/chat/room/:id/gallery → show in media grid

Polls:
POST /command/chat/message (with pollQuestion/pollOptions) → POST /command/chat/poll/:messageId to vote
```
