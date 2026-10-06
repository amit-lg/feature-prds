# Support Ticket System

## Overview

A structured way for a student to raise an issue and have it tracked through to resolution by an employee. A ticket is a **case record** (subject, category, priority, status, assignee) layered on top of the *existing* chat system — it does **not** get its own message table. Every ticket gets a dedicated `ChatRoom` (new `ChatRoomType = 'Ticket'`), and the actual conversation is just ordinary `ChatRoomMessage` rows sent through the chat endpoints that already exist (`POST /communicate/message` for the student, `POST /command/chat/message` for the employee). A message is tied to its ticket the same way a message is already tied to a lecture/practice-question/quiz-question today: a small join table (`ChatRoomMessageToTicket`), populated from a new `ticketIds` field on the existing `SendMessageDto` — mirroring `practiceIds`/`mockIds`/`lectureIds` exactly.

This means the ticket module ships with almost no new messaging code: no new send-message endpoint, no new message-list endpoint, no new "new message" socket event, no new attachment-upload code. It only adds the case-tracking layer (create/claim/resolve/close/reopen) and reuses everything else.

---

## Pre-existing Schema (no changes needed for these — reused as-is)

| Model | Relevance |
|---|---|
| `ChatRoom` | One row per ticket, `type = 'Ticket'`; scalar `platformId` already exists on this model |
| `ChatRoomMessage` | The actual ticket messages — `userId`/`employeeId`, `attachment` (`Json?`), reactions, pins, views, all already built |
| `ChatroomToUsers` | Student's membership in the ticket's room |
| `ChatroomToEmployees` | Assigned employee's membership in the ticket's room (added on claim) |
| `ChatRoomMessageToPracticeQuestion` (and `...ToQuizQuestion`, `...ToLectureGuide`) | **The precedent this feature copies.** A 2-column join (`messageId`, `questionId`) populated from `SendMessageDto.practiceIds` inside `sendMessage`/`sendEmployeeMessage` in `src/communicate/communicate.service.ts`, right after the `ChatRoomMessage` is created |
| `SendMessageDto` (`src/communicate/dto/send-message.dto.ts`) | Already has `roomId`, `message`, `lectureIds`, `doubtIds`, `practiceIds`, `mockIds` — gets one more optional field, `ticketIds` |

**Correction vs. `docs/employee-communication.md`:** that doc says the chat service lives at `src/command/command.communicate.service.ts` — that file doesn't exist. The real, live implementation for both the student and employee sides is `src/communicate/communicate.service.ts` (~15,500 lines), used via `CommunicateService` injected into both `src/communicate/communicate.controller.ts` (student routes, prefix `/communicate`) and `src/command/command.controller.ts` (employee `chat/*` routes, prefix `/command/chat`).

---

## Schema Changes

### `ChatRoomType` enum — add one value

```prisma
enum ChatRoomType {
  Friend
  Group
  Broadcast
  Course
  Desk
  Platform
  lead
  Ticket   // new
}
```

### `Ticket` model — the case record (no message fields)

```prisma
model Ticket {
  id          Int       @id @default(autoincrement())
  userId      Int
  platformId  Int
  chatroomId  Int       // the dedicated ChatRoom for this ticket's conversation
  subject     String
  category    String?   // free-form, e.g. "payment", "technical", "course-access"
  priority    String    @default("medium") // low, medium, high
  status      String    @default("open")   // open, in_progress, resolved, closed
  employeeId  Int?      // assigned handler; null = unassigned, sits in the open queue
  resolvedAt  DateTime?
  closedAt    DateTime?
  createdAt   DateTime  @default(now())
  updatedAt   DateTime  @updatedAt
  User        User      @relation(fields: [userId], references: [id])
  Employee    Employee? @relation(fields: [employeeId], references: [id])
  Platform    Platform  @relation(fields: [platformId], references: [id])
  ChatRoom    ChatRoom  @relation(fields: [chatroomId], references: [id])
  Messages    ChatRoomMessageToTicket[]

  @@index([platformId, status])
  @@index([employeeId])
  @@index([userId])
}
```

No `description`/`attachments` fields on `Ticket` — the initial issue description **is** the first `ChatRoomMessage` in the ticket's room (see Ticket Creation Flow below), same as every other message.

### `ChatRoomMessageToTicket` — the join table, shaped exactly like `ChatRoomMessageToPracticeQuestion`

```prisma
model ChatRoomMessageToTicket {
  id        Int             @id @default(autoincrement())
  messageId Int
  ticketId  Int
  Message   ChatRoomMessage @relation(fields: [messageId], references: [id])
  Ticket    Ticket          @relation(fields: [ticketId], references: [id])
}
```

Add the reverse relation (`Tickets Ticket[]`, `Messages ChatRoomMessageToTicket[]`, etc.) on `ChatRoom`, `ChatRoomMessage`, `User`, `Employee`, and `Platform` where Prisma requires it.

Run `npx prisma migrate dev --name add_ticket_system` (never `prisma db push`), then `npx prisma generate`.

---

## `SendMessageDto` Change

`src/communicate/dto/send-message.dto.ts` gets one new optional field, next to `practiceIds`/`mockIds`/`lectureIds`:

```ts
@IsOptional()
@IsArray()
@Type(() => Number)
ticketIds?: number[];
```

In `src/communicate/communicate.service.ts`, both `sendMessage` (student) and `sendEmployeeMessage` (employee) get one more loop after the message is created — copy the existing `practiceIds` loop verbatim, swapping in `chatRoomMessageToTicket`:

```ts
if (dto.ticketIds?.length) {
  for (const ticketId of dto.ticketIds) {
    await this.databaseService.chatRoomMessageToTicket.create({
      data: { ticketId, messageId: chatRoomMessage.id },
    });
  }
}
```

That's the entire messaging-side change. Sending and listing ticket messages afterwards uses the endpoints that already exist — nothing ticket-specific to build there.

---

## Status Lifecycle

```
open          — unassigned, sitting in the queue (student is the only room member)
  ↓ claim (employee joins the room as a ChatroomToEmployees member, employeeId set)
in_progress   — actively being worked
  ↓ resolve                              ↓ close (e.g. duplicate/invalid, skips resolved)
resolved      — fixed, awaiting confirmation      closed — final
  ↓ close            ↓ reopen (student, unsatisfied)
closed        — final                    in_progress — same employeeId, room membership untouched
```

Reopening sets `status` back to `in_progress` if `employeeId` is still set (the employee stays a room member throughout — claiming never removes them), or `open` if somehow unassigned.

---

## New Module: `src/ticket/`

```
src/ticket/
  ticket.module.ts
  ticket.controller.ts
  ticket.service.ts        (injects CommunicateService for room/message creation)
  dto/
    create-ticket.dto.ts
    get-tickets.dto.ts
```

Register in `src/app.module.ts`. `PlatformCheckMiddleware` wired via `configure()` per CLAUDE.md convention.

---

## API Endpoints

All under `/ticket` (global prefix `/api` applies on top).

### Student-Facing (`@UseGuards(AuthGuard)`)

#### `POST /ticket`
Creates a ticket. **This is the only endpoint that touches the chat system on the ticket module's behalf** — everything after creation goes straight through `/communicate/*`.

**Body** (`multipart/form-data`, attachment optional — same field the chat system already accepts):
```json
{
  "subject": "Payment deducted but course not unlocked",
  "description": "I paid for the JEE 2026 batch but it's not showing in my courses.",
  "category": "payment",
  "priority": "high"
}
```

**What it does internally:**
1. Create a `ChatRoom` (`type: 'Ticket'`, `platformId`) + a `ChatroomToUsers` row for the student.
2. Create the `Ticket` row (`chatroomId` from step 1, `status: 'open'`).
3. Call `communicateService.sendMessage(userId, platformId, { roomId: chatroom.id, message: description, ticketIds: [ticket.id] }, uploadedFile, token)` — the description becomes message #1, tagged to the ticket via the new join row, attachment handled by the chat system's existing upload path.

**Response:** the created `Ticket` (including `chatroomId`) plus the first message, e.g.:
```json
{
  "id": 12,
  "subject": "Payment deducted but course not unlocked",
  "category": "payment",
  "priority": "high",
  "status": "open",
  "chatroomId": 88,
  "employeeId": null,
  "createdAt": "2026-07-01T10:00:00Z"
}
```

---

#### `GET /ticket?status=&page=`
Lists the student's own tickets (case metadata only — no messages), newest first. Query: `status?`, `page?` (0-indexed, 20/page).

---

#### `GET /ticket/:ticketId`
Ticket case detail. `403` if it doesn't belong to the requesting student.

**Response:**
```json
{
  "id": 12,
  "subject": "Payment deducted but course not unlocked",
  "category": "payment",
  "priority": "high",
  "status": "in_progress",
  "chatroomId": 88,
  "employeeId": 5,
  "resolvedAt": null,
  "closedAt": null,
  "createdAt": "2026-07-01T10:00:00Z"
}
```

To load the conversation, the frontend calls the **existing** `GET /communicate/messages/:roomId?page=` with `roomId = chatroomid`. To reply, `POST /communicate/message` with `{ roomId: chatroomId, message, ticketIds: [ticketId] }`. No ticket-specific message endpoints exist.

---

#### `PATCH /ticket/:ticketId/reopen`
Reopens a `resolved`/`closed` ticket the student owns. `400` if already `open`/`in_progress`.

---

### Employee-Facing (`@UseGuards(EmployeeAuthGuard)`)

Permission-checked via `EmployePermissionCheck.checkPermission`, instantiated manually in the service constructor (matches `doubtforum.service.ts`), not DI-injected.

#### `GET /ticket/command/queue?category=&priority=&page=`
Unassigned (`status = 'open'`) tickets. Permission: `canViewTickets`.

#### `GET /ticket/command/mine?status=&page=`
Tickets assigned to the requesting employee. Permission: `canViewTickets`.

#### `GET /ticket/command/stats`
Permission: `canViewTickets`. Response: `{ total, open, inProgress, resolved, closed }`.

#### `GET /ticket/command/:ticketId`
Case detail (same shape as the student one, plus the ticket owner's name). Permission: `canViewTickets`.

#### `PATCH /ticket/command/:ticketId/claim`
Permission: `canManageTickets`. Race-safe via a `$transaction` + `updateMany` guarded on `employeeId: null, status: 'open'` (same technique as lead claiming in `lead.service.ts`) — loser gets `400 "Ticket already claimed or not open"`. On success, also creates the `ChatroomToEmployees` row so the employee can now see/send in the room via the existing chat endpoints.

#### `PATCH /ticket/command/:ticketId/resolve`
Sets `resolvedAt`. Must be the assigned employee.

#### `PATCH /ticket/command/:ticketId/close`
Sets `closedAt`. Must be the assigned employee. Callable directly from `in_progress` or from `resolved`.

**Employee replies and message listing:** `POST /command/chat/message` / `GET /command/chat/room/:roomId/messages?page=` — both already exist, both already require the employee to be a room member (enforced by `assertEmployeeMember`), which `claim` just satisfied.

---

## Real-Time

Because replies are ordinary `ChatRoomMessage`s in an ordinary `ChatRoom`, the **existing** `new_message` socket event (emitted to `chat_room_${roomId}` on both `/user` and `/employee`, per `docs/employee-communication.md`) already delivers ticket replies live — no new "new ticket message" event needed.

Two things genuinely don't exist yet and need adding:

| Event | Namespace / Room | Trigger | Why it's new |
|---|---|---|---|
| `new_ticket` | `/employee` → `ticket_queue_${platformId}` | Ticket created | There's no "unassigned queue" concept in chat to hook into |
| `ticket_status_changed` | `/user` + `/employee` → `chat_room_${chatroomId}` | Claimed / resolved / closed / reopened | Status isn't a chat concept |

**Employee queue room join:** on `/employee` connect, if the employee has `canViewTickets`, join `ticket_queue_${platformId}` — add alongside the existing `joinEmployeeChatRooms(client, employeeId)` call in `employee.gateway.ts`'s `handleConnection`.

**Verify during implementation:** confirm the `/user` socket already auto-joins a student's existing `chat_room_${id}` rooms on login (mirroring `joinEmployeeChatRooms` on the employee side) — `src/auth/auth.service.ts`'s `wsLogin` wasn't fully traced for this. If it doesn't, the newly created ticket room needs an explicit join call added to that same login flow (or the frontend joins on demand when opening the ticket screen); either way this is a few-line addition, not new infrastructure.

---

## Permission Strings

Two new flat camelCase strings in `permissionsStrings.txt` (this codebase doesn't use dot-separated strings):

```
canViewTickets    — see the queue, assigned tickets, stats, ticket detail
canManageTickets  — claim, resolve, close
```

(Sending/reading messages is gated by the existing chat system's own room-membership check, not a ticket permission.)

---

## Where Code Lives

| What | File |
|---|---|
| Schema change | `prisma/schema.prisma` — `ChatRoomType.Ticket`, `Ticket`, `ChatRoomMessageToTicket` |
| `SendMessageDto` change | `src/communicate/dto/send-message.dto.ts` — add `ticketIds?: number[]` |
| Message-tagging loop | `src/communicate/communicate.service.ts` — inside `sendMessage` and `sendEmployeeMessage`, mirroring the existing `practiceIds` loop |
| New module | `src/ticket/ticket.module.ts`, `ticket.controller.ts`, `ticket.service.ts` (injects `CommunicateService` for room creation + posting the first message) |
| Employee queue room join | `src/employee/employee.service.ts` (new `joinTicketQueueRoom`), called from `src/employee/employee.gateway.ts`'s `handleConnection` |
| Permission strings | `permissionsStrings.txt` — `canViewTickets`, `canManageTickets` |

Explicitly **not** touched: `src/vultr/` (attachment upload already wired through `sendMessage`/`sendEmployeeMessage`), any new message-list/send-message/typing/reaction/pin endpoint (all reused as-is from `/communicate` and `/command/chat`).

---

## Edge Cases

| Case | Behaviour |
|---|---|
| Two employees claim the same ticket at once | Only one `updateMany` succeeds; the other gets `400` |
| Employee tries to resolve/close a ticket not assigned to them | `403 Forbidden` |
| Employee tries to reply/read messages in a ticket room they haven't claimed | `403` — enforced by the existing `assertEmployeeMember` check in `sendEmployeeMessage`, nothing ticket-specific to add |
| Student replies to a `closed` ticket | Not blocked by the ticket module — flag: decide whether `sendMessage` should check for a closed ticket via the `ChatRoomMessageToTicket`/`Ticket.chatroomId` link, or whether this is acceptable (message still lands, ticket stays closed until reopened) |
| Student reopens a ticket that's still `open`/`in_progress` | `400 Bad Request` |
| Student tries to view another student's ticket case data | `403 Forbidden` (chat room membership already prevents them from reading messages either way) |
| Employee without `canViewTickets`/`canManageTickets` hits ticket-case endpoints | `403 Forbidden` |

---

## Frontend Instructions

### 1. Socket Setup

Reuse the existing `/user` or `/employee` socket connection — ticket replies arrive via the **existing** `new_message` event once the client is a member of `chat_room_${chatroomId}` (automatic on login/connect, same as any other room).

```js
socket.on('new_message',           (msg)  => { /* append to open ticket thread, same handler as chat */ })
socket.on('ticket_status_changed',  (data) => { /* update status badge */ })
// employee app only:
socket.on('new_ticket', (ticket) => { /* prepend to queue list if queue screen is open */ })
```

---

### 2. Student — Raising a Ticket

"New Ticket" form: `subject`, `description`, `category` (dropdown), `priority` (optional), one attachment (optional — same single-file upload the chat composer already supports).

On submit: `POST /ticket`. On success, navigate to the ticket detail screen using the returned `chatroomId`.

---

### 3. Student — My Tickets List

`GET /ticket?page=0`, optionally filtered by a status tab. Show status badge (see below) and last-updated time.

---

### 4. Student — Ticket Detail

`GET /ticket/:ticketId` for case metadata (status, category, priority). For the conversation itself, treat it exactly like any other chat room:
- Load messages: `GET /communicate/messages/:chatroomId?page=1`
- Send a reply: `POST /communicate/message` with `{ roomId: chatroomId, message, ticketIds: [ticketId] }` (`ticketIds` only matters for tagging — the frontend just always includes it for messages sent from a ticket screen)
- If `status` is `resolved`/`closed`: show "Marked resolved. Still an issue?" with a **Reopen** button (`PATCH /ticket/:ticketId/reopen`)

---

### 5. Employee — Ticket Queue

Visible only with `canViewTickets`. `GET /ticket/command/queue`, filterable by `category`/`priority`. **Claim** button → `PATCH /ticket/command/:ticketId/claim`, then navigate into the ticket using the same chat-room UI the employee chat already has (`GET /command/chat/room/:roomId/messages`, `POST /command/chat/message` with `ticketIds`).

Live updates: `new_ticket` socket event prepends a new row without a refresh.

---

### 6. Employee — My Tickets

`GET /ticket/command/mine`, filterable by `status`. Same chat UI as the queue detail, plus:
- Resolve → `PATCH /ticket/command/:ticketId/resolve`
- Close → `PATCH /ticket/command/:ticketId/close`

---

### 7. Status Badges

| Status | Badge colour | Label |
|---|---|---|
| `open` | Grey | Open |
| `in_progress` | Blue | In Progress |
| `resolved` | Green | Resolved |
| `closed` | Muted | Closed |

---

### 8. Flow Summary

```
Student:
  New Ticket form → POST /ticket  (creates room + posts description as message #1)
  My Tickets → GET /ticket → tap row → GET /ticket/:id (case) + GET /communicate/messages/:chatroomId (thread)
  Reply → POST /communicate/message  { roomId: chatroomId, message, ticketIds: [id] }
  Reopen (if resolved/closed) → PATCH /ticket/:id/reopen

Employee (needs canViewTickets / canManageTickets):
  Queue → GET /ticket/command/queue → Claim → PATCH /ticket/command/:id/claim
  My Tickets → GET /ticket/command/mine → tap row → GET /ticket/command/:id (case) + GET /command/chat/room/:chatroomId/messages (thread)
  Reply → POST /command/chat/message  { roomId: chatroomId, message, ticketIds: [id] }
  Resolve → PATCH /ticket/command/:id/resolve
  Close → PATCH /ticket/command/:id/close

Real-time (both sides — nothing ticket-specific to join, chat rooms auto-join on connect):
  socket.on('new_message', ...)            ← existing chat event, works as-is
  socket.on('ticket_status_changed', ...)  ← new, ticket-only
  socket.on('new_ticket', ...)              ← new, employee queue only
```
