# Employee Chat Moderation & Admin Messaging — Product Design

Status: Draft
Owner: TBD
Related code: `src/communicate/`, `src/command/command.controller.ts`, `src/notification/notification.service.ts`

## 1. Problem

Employees (support/ops staff on the command side) currently have no unified way to:

1. See the full set of chat rooms a user participates in — group chats, broadcasts, DMs/friend chats — not just Ticket-linked rooms.
2. See which messages or users have been reported by other users.
3. Reply into a room in a way that reads as **"Admin"** on the user's side, rather than exposing the individual employee's name/profile.

Today, `src/communicate/communicate.service.ts` (employee-facing methods around lines 15690–16155, exposed via `command.controller.ts:6008-6047`) only lets an employee view/reply to **Ticket-type** rooms they've claimed. There is no reporting model for chat at all — `ChatRoomMessage` only has a soft-hide flag (`isVisible`), and staff replies always surface as the real employee via the `Employee` relation.

## 2. Goals

- Give permissioned employees a single "Chat Moderation" surface to browse all of a platform's chat rooms (group + personal), independent of ticket linkage.
- Let users report a message or a user; surface those reports to employees with enough context to act.
- Let employees reply into any room as **"Admin"** — the user sees a masked identity, not the employee's name.
- Let employees take action on a report: dismiss, hide message, mute/ban user, escalate.

### Non-goals (v1)

- Employee-to-employee moderation of `/employee` or `/command` internal chat — this is about user-facing chat only.
- Automated/ML content moderation. This is a manual review tool.
- Changing the existing Ticket-scoped flow — it stays as-is and becomes a filtered view within the new surface.

## 3. Data model changes

### 3.1 New: message & user reports

```prisma
model ChatMessageReport {
  id            String    @id @default(uuid())
  platformId    String
  chatRoomId    String
  messageId     String
  reportedById  String    // User who filed the report
  reason        String    // enum-like string, see ReportReason below
  note          String?   // free-text detail from reporter
  status        ReportStatus @default(OPEN)
  resolvedById  String?   // Employee who actioned it
  resolvedAt    DateTime?
  resolutionNote String?
  createdAt     DateTime  @default(now())
  updatedAt     DateTime  @updatedAt

  platform      Platform        @relation(fields: [platformId], references: [id])
  chatRoom      ChatRoom        @relation(fields: [chatRoomId], references: [id])
  message       ChatRoomMessage @relation(fields: [messageId], references: [id])
  reportedBy    User            @relation(fields: [reportedById], references: [id])
  resolvedBy    Employee?       @relation(fields: [resolvedById], references: [id])

  @@index([chatRoomId])
  @@index([status])
}

model ChatUserReport {
  id            String    @id @default(uuid())
  platformId    String
  chatRoomId    String?   // optional: room context the report originated in
  reportedUserId String
  reportedById  String
  reason        String
  note          String?
  status        ReportStatus @default(OPEN)
  resolvedById  String?
  resolvedAt    DateTime?
  resolutionNote String?
  createdAt     DateTime  @default(now())
  updatedAt     DateTime  @updatedAt

  platform      Platform  @relation(fields: [platformId], references: [id])
  reportedUser  User      @relation("ReportedUser", fields: [reportedUserId], references: [id])
  reportedBy    User      @relation("ReportingUser", fields: [reportedById], references: [id])
  resolvedBy    Employee? @relation(fields: [resolvedById], references: [id])

  @@index([reportedUserId])
  @@index([status])
}

enum ReportStatus {
  OPEN
  IN_REVIEW
  RESOLVED
  DISMISSED
}
```

`reason` stays a plain string (not a DB enum) to match the existing loose-typing convention (`DoubtQuestionReport`, `FormulaToUserToReport`) — validate against a fixed set in the DTO instead: `spam`, `harassment`, `inappropriate_content`, `scam`, `other`.

### 3.2 Admin-masked sender

`ChatRoomMessage` needs a way to say "this message came from staff, but display it as Admin." Add one nullable field rather than a boolean, so we can later support named personas (e.g. "Support", "Moderator") without another migration:

```prisma
model ChatRoomMessage {
  // ...existing fields
  displayAs   String?   // e.g. "Admin" — when set, overrides employee name/avatar on the user side
}
```

Rule: `employeeId != null && displayAs != null` → render with the platform's default "Admin" avatar/name and hide `employeeId` from the user-facing payload. `employeeId` is still stored for audit/traceability — only the *serialized response to `/user` namespace clients* masks it. Employee-side and command-side views always show the real employee for accountability.

## 4. Permissions

Add to `permissionsStrings.txt` under a new "Chat Moderation" section:

- `canViewUserChats` — browse all rooms/messages for the platform (read-only).
- `canReplyAsAdmin` — send messages into a user room with `displayAs = "Admin"`.
- `canViewChatReports` — see the reports queue.
- `canResolveChatReports` — dismiss/resolve reports, and take the associated moderation action (hide message, mute/ban user).

Note the existing drift: `communicate.service.ts:29` already checks `'canViewStudentEnquary'` for the Ticket-scoped employee room view, which isn't in `permissionsStrings.txt`. Reconcile by either renaming that check to `canViewUserChats` (subsuming it, since the new surface is a superset) or keeping it separate if Ticket rooms should stay behind their own permission. Recommend: **subsume it** — `canViewUserChats` gates the whole surface, Ticket rooms become one filter within it.

## 5. API design

All under `src/command/` (or a new `src/chat-moderation/` module if `command.controller.ts` is too large already — it's currently 494 lines and `communicate.service.ts` is 16.6k lines, so a **new dedicated module** is preferable to piling more onto either file).

```
GET  /command/chat-moderation/rooms
  ?type=Group|Friend|Broadcast|...&search=&hasOpenReport=&page=&limit=
  → paginated list of ChatRoom for the platform, with participant summary,
    last message preview, and an openReportCount badge.

GET  /command/chat-moderation/rooms/:roomId/messages
  ?before=<messageId>&limit=
  → paginated message history for the room (any room type, not just Ticket).

POST /command/chat-moderation/rooms/:roomId/messages
  body: { content, attachments? }
  → creates a ChatRoomMessage with employeeId = req.employeeId, displayAs = "Admin".
    Requires canReplyAsAdmin. Emits to `/user` namespace, room `chat_room_<roomId>`,
    via NotificationService.sendNotification — reuses the existing emit pattern.

GET  /command/chat-moderation/reports
  ?status=OPEN&type=message|user&page=&limit=
  → merged/paginated feed of ChatMessageReport + ChatUserReport, newest first.

GET  /command/chat-moderation/reports/:id
  → full detail: reporter, reported message/user, room context, prior reports
    against the same message/user (repeat-offender signal).

POST /command/chat-moderation/reports/:id/resolve
  body: { status: RESOLVED|DISMISSED, resolutionNote?, action?: 'hideMessage'|'muteUser'|'banUser' }
  → updates report, optionally cascades: sets ChatRoomMessage.isVisible = false,
    or calls existing UserBanService / a new chat-scoped mute.
```

User-facing addition (existing `communicate.controller.ts`):

```
POST /communicate/messages/:messageId/report
POST /communicate/users/:userId/report
  body: { reason, note? }
  → creates ChatMessageReport / ChatUserReport as reportedById = req.userId.
```

## 6. Realtime behavior

Reuses the existing pattern documented in `notification.service.ts` — no new gateway needed:

- Admin replies: `notificationService.sendNotification('/user', 'chat_room_' + roomId, 'new-message', payload)`, mirroring `emitToUserRoomAsEmployee` (`communicate.service.ts:14771`). Payload's `sender` object is `{ id: 'admin', name: 'Admin', avatar: <platform default> }` regardless of the underlying employee.
- New report filed: emit `'chat-report-created'` to a platform-wide employee room (e.g. `platform_<id>_moderators`) on `/command`, so the moderation queue can update live without polling. Employees with `canViewChatReports` join this room the same way `joinEmployeeChatRooms` already wires room membership on connect.

## 7. UI/UX (Command console)

**Chat Moderation** section (new left-nav item, gated on `canViewUserChats`):

- **Rooms tab**: list/search all rooms, filter by type and by "has open report." Row shows room name/participants, last message snippet, unread-to-employee indicator, and a red badge with open report count.
- **Room detail**: standard chat thread view. Reported messages are highlighted (subtle red left-border) with a small flag icon; hovering shows reason + reporter. Composer at the bottom sends as "Admin" — no employee-picker, no option to send as self (keeps the mask non-optional and simple to reason about, and avoids employees accidentally deanonymizing themselves).
- **Reports queue tab** (gated on `canViewChatReports`): table of open reports, sortable by date/reason, with a "repeat offender" chip if the same user/message has ≥2 reports. Clicking a row opens a side panel with full context (message content, room, reporter, prior history) and action buttons: Dismiss / Hide Message / Mute User / Ban User (each gated on `canResolveChatReports`).
- **Audit trail**: every resolution records `resolvedById` + `resolutionNote` — surfaced on the report detail so a second employee can see who actioned it and why.

## 8. Edge cases

- **Reporting your own admin message**: a user reporting a message from "Admin" should still work — `reportedById` is the reporting user, and the message's true `employeeId` stays visible to employees reviewing the report (masking only applies to the `/user`-facing socket/API payload).
- **Room with no employee members yet**: employee sending the first admin reply should not require the employee to "join" the room first (unlike the current Ticket flow, which checks the ticket is claimed). `canReplyAsAdmin` alone should be sufecient; the message write path adds the employee to `ChatroomToEmployees` implicitly if needed for audit, without exposing that membership to users.
- **Deleted/hidden messages still reportable**: reports reference `messageId`; if a message is later hidden (`isVisible = false`) via a different report's resolution, existing open reports on it should auto-resolve as `RESOLVED` with a system-generated `resolutionNote` rather than dangling.
- **Rate-limiting reports**: cap reports per user per hour (reuse whatever throttling pattern exists elsewhere, e.g. guard-level) to prevent report-flooding as a griefing vector against another user.

## 9. Rollout

1. **Migration**: add `ChatMessageReport`, `ChatUserReport`, `ReportStatus` enum, `ChatRoomMessage.displayAs`.
2. **Permissions**: add the four strings to `permissionsStrings.txt`; reconcile `canViewStudentEnquary`.
3. **Backend**: new `src/chat-moderation/` module (controller + service), reusing `DatabaseService` and `NotificationService`; two new endpoints on `communicate.controller.ts` for user-side reporting.
4. **Frontend** (command console): Chat Moderation nav section — Rooms, Room detail, Reports queue.
5. **Migrate Ticket-scoped flow**: keep `GET /command/chat/user-rooms*` working (or thin them to delegate into the new service) so nothing breaks for existing Ticket-based support flows.

## 10. Open questions

- Should "Admin" be a single global persona per platform, or should platforms be able to configure a custom display name/avatar (e.g. "Support Team")? Design above assumes a single per-platform default (simplest v1); a `PlatformAdminPersona` config table is a natural v2 extension.
- Should muting/banning a user from chat be chat-scoped only, or should `POST .../resolve` with `action: 'banUser'` reuse the existing generic `UserBanService` (`service` string ban) and just pass `service: 'chat'`? Recommend reusing `UserBanService` to avoid a parallel ban mechanism.
- Do broadcast-type rooms need reporting at all (one-to-many, sender is usually staff/platform)? Likely exclude `Broadcast` rooms from the report entry points on the user side.
