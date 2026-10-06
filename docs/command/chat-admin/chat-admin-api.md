# Chat Admin API

**Module:** `src/command/chat-admin/`
**Base path:** `api/command/chat-admin`
**Auth:** All employee routes require `Authorization: Bearer <employee-jwt>`. User-facing report routes require `Authorization: Bearer <user-jwt>`.
**Platform resolution:** Resolved from the `origin` header by `PlatformAdminCheckMiddleware` â€” no need to pass `platformId` explicitly.

---

## Overview

The Chat Admin module gives permissioned employees a unified surface to:

1. Browse all user-facing chat rooms on the platform (excluding `EmployeeGroup` internal rooms).
2. Read full message history for any room.
3. Reply into any room with identity masked as "Admin".
4. View and resolve user-filed reports on messages and users.

It does **not** touch the existing Ticket-scoped chat flow â€” that flow continues to work through `command/chat/user-rooms`.

---

## Permissions

| Permission string       | Gates |
|-------------------------|-------|
| `canViewUserChats`      | GET rooms, GET messages |
| `canReplyAsAdmin`       | POST message (send as Admin) |
| `canViewChatReports`    | GET reports, GET report detail |
| `canResolveChatReports` | POST resolve report, DELETE user ban |

Returns `403 Forbidden` if the employee lacks the required permission.

---

## Data Models

### ChatMessageReport
```
id             Int      â€” primary key
platformId     Int      â€” platform scope
chatRoomId     Int      â€” room the reported message lives in
messageId      Int      â€” the reported ChatRoomMessage
reportedById   Int      â€” User who filed the report
reason         String   â€” spam | harassment | inappropriate_content | scam | other
note           String?  â€” optional free-text from reporter
status         String   â€” OPEN | IN_REVIEW | RESOLVED | DISMISSED (default OPEN)
resolvedById   Int?     â€” Employee who actioned it
resolvedAt     DateTime?
resolutionNote String?
createdAt      DateTime
updatedAt      DateTime
```

### ChatUserReport
```
id             Int      â€” primary key
platformId     Int
chatRoomId     Int?     â€” optional room context
reportedUserId Int      â€” User being reported
reportedById   Int      â€” User who filed the report
reason         String   â€” same enum as above
note           String?
status         String   â€” OPEN | IN_REVIEW | RESOLVED | DISMISSED
resolvedById   Int?
resolvedAt     DateTime?
resolutionNote String?
createdAt      DateTime
updatedAt      DateTime
```

### ChatRoomMessage.displayAs (new field)
```
displayAs  String?  â€” when set (e.g. "Admin"), overrides employee name/avatar on user side
```
Rule: `employeeId != null && displayAs != null` â†’ render as Admin on user side. `employeeId` is always stored for audit.

---

## Endpoints

---

### 1. GET `chat-admin/rooms`

List all user-facing chat rooms for the platform. Excludes rooms with `type = EmployeeGroup`.

**Permission:** `canViewUserChats`

**Query params**

| Param           | Type    | Required | Description |
|-----------------|---------|----------|-------------|
| `type`          | string  | No       | Filter by `ChatRoomType`: `Friend`, `Group`, `Broadcast`, `Course`, `Desk`, `Platform`, `lead`, `Ticket` |
| `search`        | string  | No       | Case-insensitive search on room name or any member's first/last name |
| `hasOpenReport` | boolean | No       | `true` â†’ only rooms with â‰¥1 open report |
| `page`          | number  | No       | 0-indexed, default `0` |
| `limit`         | number  | No       | Default `20` |

**Response** `200 OK` â€” array of room objects:

```json
[
  {
    "id": 42,
    "name": "Study Group Alpha",
    "icon": "https://cdn.example.com/icon.png",
    "description": null,
    "type": "Group",
    "isBroadcast": false,
    "platformId": 1,
    "courseId": null,
    "friendId": null,
    "quizGroupId": null,
    "createdAt": "2026-07-01T10:00:00.000Z",
    "updatedAt": "2026-07-18T09:30:00.000Z",
    "Users": [
      {
        "id": 1,
        "userId": 101,
        "chatroomId": 42,
        "User": {
          "id": 101,
          "fname": "Riya",
          "lname": "Sharma",
          "profile": "https://...",
          "BannedServices": []
        }
      },
      {
        "id": 2,
        "userId": 202,
        "chatroomId": 42,
        "User": {
          "id": 202,
          "fname": "Karan",
          "lname": "Mehta",
          "profile": null,
          "BannedServices": [
            {
              "id": 6,
              "reason": "banUser",
              "createdAt": "2026-07-29T14:29:17.217Z",
              "Platform": { "id": 4, "name": "LMS" }
            }
          ]
        }
      }
    ],
    "Employees": [
      {
        "id": 2,
        "employeeId": 7,
        "chatroomId": 42,
        "isAdmin": false,
        "Employee": { "id": 7, "fname": "Arjun", "lname": "Verma", "profile": "https://..." }
      }
    ],
    "lastMessage": {
      "id": 980,
      "message": "Hey everyone!",
      "createdAt": "2026-07-18T09:30:00.000Z",
      "userId": 101,
      "employeeId": null
    },
    "openReportCount": 2
  }
]
```

- `lastMessage` â€” `null` if the room has no messages.
- `openReportCount` â€” count of `OPEN` status reports in this room.
- `BannedServices` â€” empty array means user is not banned from chat. Non-empty means the user is banned â€” use `BannedServices[0].reason` and `BannedServices[0].Platform.name` for display.

---

### 2. GET `chat-admin/rooms/:roomId/messages`

Fetch message history for any room. Returns newest first (reverse on client to show oldest-at-top).

**Permission:** `canViewUserChats`

**Path param:** `roomId` â€” integer

**Query params**

| Param    | Type   | Required | Description |
|----------|--------|----------|-------------|
| `before` | number | No       | Cursor â€” fetch messages with `id < before` (load older) |
| `limit`  | number | No       | Default `30` |

**Response** `200 OK` â€” array:

```json
[
  {
    "id": 980,
    "message": "Hey everyone!",
    "chatroomId": 42,
    "userId": 101,
    "employeeId": null,
    "displayAs": null,
    "attachment": null,
    "type": null,
    "isVisible": true,
    "messageId": null,
    "createdAt": "2026-07-18T09:30:00.000Z",
    "updatedAt": "2026-07-18T09:30:00.000Z",
    "User": { "id": 101, "fname": "Riya", "lname": "Sharma", "profile": "https://..." },
    "Employee": null,
    "Reactions": [],
    "ParentMessage": null,
    "MessageReports": [],
    "UserMentions": [],
    "EmployeeMentions": []
  }
]
```

**Message sender rules:**

| `userId` | `employeeId` | `displayAs` | Render as |
|----------|--------------|-------------|-----------|
| set      | null         | â€”           | User (show `User` avatar/name) |
| null     | set          | null        | Employee (show `Employee` avatar/name) |
| null     | set          | `"Admin"`   | Admin message â€” show `displayAs` as label; on admin panel you may reveal the real `Employee` for accountability |

**`attachment` shape** (null when no file):
```json
{ "url": "https://cdn.example.com/file.pdf", "name": "file.pdf", "type": "application/pdf" }
```

**`ParentMessage`** â€” when the message is a reply, contains the quoted message with the same fields including `User`, `Employee`, `Reactions`, `MessageReports`, `UserMentions`, `EmployeeMentions`.

**`MessageReports`** â€” array of all reports on this message (not filtered by status). Each entry: `{ id, reason, status, resolutionAction, resolvedById }`. Use to determine render state:

| `isVisible` | Has entry with `resolutionAction: "hideMessage"` | Display |
|-------------|--------------------------------------------------|---------|
| `true`      | â€”                                                | Normal message |
| `false`     | Yes                                              | "Hidden by Admin" tag |
| `false`     | No                                               | "Deleted by user" |

---

### 3. POST `chat-admin/rooms/:roomId/messages`

Send a message into any user room as "Admin".

**Permission:** `canReplyAsAdmin`

**Content-Type:** `multipart/form-data`

**Path param:** `roomId` â€” integer

**Body fields**

| Field       | Type   | Required | Description |
|-------------|--------|----------|-------------|
| `message`   | string | No       | Text content |
| `displayAs` | string | No       | Display name â€” defaults to `"Admin"` if omitted |
| `file`      | file   | No       | Attachment (image, document, etc.) |

**Response** `201 Created` â€” created message object, same shape as section 2 (includes real `Employee` object for admin audit):

```json
{
  "id": 981,
  "message": "Please keep the discussion on topic.",
  "chatroomId": 42,
  "userId": null,
  "employeeId": 7,
  "displayAs": "Admin",
  "attachment": null,
  "isVisible": true,
  "createdAt": "2026-07-22T10:00:00.000Z",
  "User": null,
  "Employee": { "id": 7, "fname": "Arjun", "lname": "Verma", "profile": "https://..." },
  "Reactions": [],
  "ParentMessage": null,
  "MessageReports": [],
  "UserMentions": [],
  "EmployeeMentions": []
}
```

**Socket event emitted** â€” namespace `/user`, room `chat_room_<roomId>`, event `new_message`:
- Same payload but `Employee: null` â€” user side detects admin message via `employeeId != null && Employee == null` and renders using `displayAs`.

---

### 4. GET `chat-admin/reports`

Paginated feed of message and user reports. Supports filtering by status, type, and room.

**Permission:** `canViewChatReports`

**Query params**

| Param    | Type   | Required | Description |
|----------|--------|----------|-------------|
| `status` | string | No       | `OPEN`, `IN_REVIEW`, `RESOLVED`, `DISMISSED` |
| `type`   | string | No       | `message` or `user` â€” omit to get both merged |
| `roomId` | number | No       | Filter reports scoped to a specific chat room |
| `page`   | number | No       | 0-indexed, default `0` |
| `limit`  | number | No       | Default `20` |

**Response** `200 OK` â€” paginated object, `data` sorted `createdAt` desc. Each item has a `reportType` field:

```json
{
  "data": [
    {
      "id": 3,
      "reportType": "message",
      "platformId": 1,
      "chatRoomId": 42,
      "messageId": 975,
      "reportedById": 101,
      "reason": "spam",
      "note": "Sent the same link 5 times",
      "status": "OPEN",
      "resolvedById": null,
      "resolvedAt": null,
      "resolutionNote": null,
      "createdAt": "2026-07-18T10:00:00.000Z",
      "Message": { "id": 975, "message": "Buy now...", "chatroomId": 42, "isVisible": true },
      "ReportedBy": { "id": 101, "fname": "Riya", "lname": "Sharma" },
      "ResolvedBy": null
    },
    {
      "id": 5,
      "reportType": "user",
      "platformId": 1,
      "chatRoomId": null,
      "reportedUserId": 202,
      "reportedById": 101,
      "reason": "harassment",
      "note": null,
      "status": "OPEN",
      "resolvedById": null,
      "resolvedAt": null,
      "resolutionNote": null,
      "createdAt": "2026-07-18T09:45:00.000Z",
      "ReportedUser": { "id": 202, "fname": "Karan", "lname": "Mehta" },
      "ReportedBy": { "id": 101, "fname": "Riya", "lname": "Sharma" },
      "ResolvedBy": null
    }
  ],
  "total": 84,
  "page": 0,
  "limit": 20
}
```

**Pagination:**
- `total` â€” combined count across both report types (or single type if `type` filter is set)
- Total pages = `Math.ceil(total / limit)`
- Has next page = `(page + 1) * limit < total`

**Examples:**
```
# All open reports, first page
GET /reports?status=OPEN

# Reports for a specific room, message type only
GET /reports?roomId=42&type=message&status=OPEN

# Page 2 of all reports
GET /reports?page=2&limit=20
```

---

### 5. GET `chat-admin/reports/:type/:id`

Full detail for a single report including repeat-offender count.

**Permission:** `canViewChatReports`

**Path params:** `type` = `message` or `user`, `id` = integer

**Response `type=message`:**

```json
{
  "id": 3,
  "platformId": 1,
  "chatRoomId": 42,
  "messageId": 975,
  "reportedById": 101,
  "reason": "spam",
  "note": "Sent the same link 5 times",
  "status": "OPEN",
  "resolvedById": null,
  "resolvedAt": null,
  "resolutionNote": null,
  "createdAt": "2026-07-18T10:00:00.000Z",
  "priorReportCount": 2,
  "Message": {
    "id": 975,
    "message": "Buy now...",
    "chatroomId": 42,
    "isVisible": true,
    "User": { "id": 101, "fname": "Riya", "lname": "Sharma" },
    "Employee": null,
    "ChatRoom": { "id": 42, "name": "Study Group Alpha", "type": "Group" }
  },
  "ReportedBy": { "id": 101, "fname": "Riya", "lname": "Sharma", "phone": "9999999999" },
  "ResolvedBy": null
}
```

**Response `type=user`:**

```json
{
  "id": 5,
  "platformId": 1,
  "reportedUserId": 202,
  "reportedById": 101,
  "reason": "harassment",
  "status": "OPEN",
  "priorReportCount": 1,
  "ReportedUser": { "id": 202, "fname": "Karan", "lname": "Mehta", "phone": "8888888888" },
  "ReportedBy": { "id": 101, "fname": "Riya", "lname": "Sharma" },
  "ResolvedBy": null
}
```

- `priorReportCount` â€” other reports against the same message/user (excluding this one). Signal for repeat offenders.

---

### 6. POST `chat-admin/reports/:type/:id/resolve`

Resolve or dismiss a report with an optional moderation action.

**Permission:** `canResolveChatReports`

**Path params:** `type` = `message` or `user`, `id` = integer

**Body (JSON):**

```json
{
  "status": "RESOLVED",
  "resolutionNote": "Message confirmed as spam, hidden.",
  "action": "hideMessage"
}
```

| Field            | Type   | Required | Values |
|------------------|--------|----------|--------|
| `status`         | string | Yes      | `RESOLVED`, `DISMISSED`, `IN_REVIEW` |
| `resolutionNote` | string | No       | Audit note stored on the report |
| `action`         | string | No       | `hideMessage`, `muteUser`, `banUser` |

**Action side effects:**

| Action        | Effect |
|---------------|--------|
| `hideMessage` | Sets `ChatRoomMessage.isVisible = false`. All other `OPEN` reports on the same message are auto-resolved with a system `resolutionNote`. Only valid for `type=message`. |
| `muteUser`    | Creates a `UserBanService` record with `service = "chat"` for the reported user. |
| `banUser`     | Same as `muteUser` â€” differentiate the UI label only. |

**Response** `200 OK` â€” updated report object.

---

### 7. GET `chat-admin/reports/message/by-message/:messageId`

Fetch all reports filed against a specific message.

**Permission:** `canViewChatReports`

**Path param:** `messageId` â€” integer

**Response** `200 OK` â€” array of `ChatMessageReport` objects (same shape as items in section 4 with `reportType: "message"`):

```json
[
  {
    "id": 3,
    "platformId": 1,
    "chatRoomId": 42,
    "messageId": 975,
    "reportedById": 101,
    "reason": "spam",
    "note": null,
    "status": "OPEN",
    "resolvedById": null,
    "resolvedAt": null,
    "resolutionNote": null,
    "createdAt": "2026-07-18T10:00:00.000Z",
    "Message": { "id": 975, "message": "Buy now...", "chatroomId": 42, "isVisible": true },
    "ReportedBy": { "id": 101, "fname": "Riya", "lname": "Sharma" },
    "ResolvedBy": null
  }
]
```

---

### 8. POST `chat-admin/rooms/:roomId/monitor`

Subscribe the calling employee's active `/employee` socket to live messages from this user room. After calling this, the employee receives `new_message_recieved` events on the `/employee` namespace for every user message sent in the room.

**Permission:** `canViewUserChats`

**Path param:** `roomId` â€” integer

**Response** `200 OK`:
```json
{ "monitoring": true, "roomId": 42 }
```

**Returns `409 Conflict`** if the employee is already monitoring this room.

**Socket event received after monitoring:**
- Namespace: `/employee`
- Event: `new_message_recieved`
- Payload: flat message object, same shape as items returned by `GET chat-admin/rooms/:roomId/messages`

> **Note:** Socket membership is session-only. If the employee disconnects and reconnects, `monitor` must be called again. Does **not** add the employee as a DB member of the room.

---

### 9. DELETE `chat-admin/rooms/:roomId/monitor`

Unsubscribe the calling employee's socket from live messages for this room.

**Permission:** `canViewUserChats`

**Path param:** `roomId` â€” integer

**Response** `200 OK`:
```json
{ "monitoring": false, "roomId": 42 }
```

---

### 10. DELETE `chat-admin/users/:userId/ban`

Remove a chat ban for a user. The ban is looked up by `userId` and `service: "chat"` regardless of platform.

**Permission:** `canResolveChatReports`

**Path param:** `userId` â€” integer

**Response** `200 OK`:
```json
{ "unbanned": true, "userId": 594 }
```

**Error responses:**

| Status | Reason |
|--------|--------|
| `403 Forbidden` | Employee lacks `canResolveChatReports` permission |
| `404 Not Found` | User has no active chat ban |

---

### 11. POST `communicate/report/message/:messageId`

**Auth:** User JWT (`AuthGuard`)
**Base path:** `api/communicate`

File a report against a specific message.

**Path param:** `messageId` â€” integer

**Body (JSON):**

```json
{ "reason": "spam", "note": "Optional detail" }
```

| Field    | Type   | Required | Values |
|----------|--------|----------|--------|
| `reason` | string | Yes      | `spam`, `harassment`, `inappropriate_content`, `scam`, `other` |
| `note`   | string | No       | Free-text detail |

**Response** `201 Created` â€” created `ChatMessageReport` record.

---

### 12. POST `communicate/report/user/:userId`

**Auth:** User JWT (`AuthGuard`)
**Base path:** `api/communicate`

File a report against a user.

**Path param:** `userId` â€” integer (the user being reported)

**Body (JSON):**

```json
{ "reason": "harassment", "note": "Optional detail", "chatRoomId": 42 }
```

| Field        | Type   | Required | Description |
|--------------|--------|----------|-------------|
| `reason`     | string | Yes      | Same enum as above |
| `note`       | string | No       | Free-text detail |
| `chatRoomId` | number | No       | Room context where the report originated |

**Response** `201 Created` â€” created `ChatUserReport` record.

---

## Error Responses

| Status | When |
|--------|------|
| `401 Unauthorized` | Missing or invalid JWT, or token `path` not `command` |
| `403 Forbidden` | Employee lacks the required permission |
| `404 Not Found` | Report or message not found |
| `404 Not Found` | User has no active chat ban (unbanUser) |
| `406 Not Acceptable` | Missing `origin`/`dauth` header (platform not resolved) |
| `409 Conflict` | Employee already monitoring the room (monitorRoom) |
