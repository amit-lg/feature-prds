# Ticket Feature — Phase 1: Ticket Module Only

> **Scope lock:** This phase builds ONLY the ticket case-tracking layer — schema + the new `../src/ticket` module + permission strings. It does **NOT** modify `../src/communicate/communicate.service.ts`, `SendMessageDto`, any gateway, or any existing route. The `CommunicateService` is *injected and called* (existing public methods only), never edited. Message tagging (`ticketIds`) and real-time socket events are **Phase 2 — out of scope here.**

---

## 1. Files To Create / Touch

| File | Action | What goes in it |
|---|---|---|
| `../prisma/schema.prisma` | **Edit** | Add `Ticket` to `ChatRoomType` enum; add `Ticket` model; add `ChatRoomMessageToTicket` model (unused in Phase 1, kept so migration runs once); add reverse relation fields on `ChatRoom`, `ChatRoomMessage`, `User`, `Employee`, `Platform` |
| `../src/ticket/ticket.module.ts` | **Create** | Module def; imports whatever module exports `CommunicateService`; register controller + service |
| `../src/ticket/ticket.controller.ts` | **Create** | All 11 routes below |
| `../src/ticket/ticket.service.ts` | **Create** | All business logic; injects `DatabaseService` + `CommunicateService`; instantiates `EmployePermissionCheck` manually in the constructor (copy the pattern from `../src/doubtforum/doubtforum.service.ts`) |
| `../src/ticket/dto/create-ticket.dto.ts` | **Create** | `subject` (required string), `category?`, `priority?` (`low\|medium\|high`, default `medium`), `description` (required string) |
| `../src/ticket/dto/get-tickets.dto.ts` | **Create** | `status?`, `category?`, `priority?`, `page?` (0-indexed, 20/page) |
| `../src/app.module.ts` | **Edit** | Register `TicketModule`; wire `PlatformCheckMiddleware` for `ticket` routes in `configure()` per CLAUDE.md convention |
| `../permissionsStrings.txt` | **Edit** | Append `canViewTickets`, `canManageTickets` (flat camelCase — no dots) |

**Files explicitly NOT to touch:** `../src/communicate/communicate.service.ts`, `../src/communicate/dto/send-message.dto.ts`, `../src/command/command.controller.ts`, `../src/employee/employee.gateway.ts`, `../src/vultr`, any existing controller/DTO/gateway.

---

## 2. Schema

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

model Ticket {
  id          Int       @id @default(autoincrement())
  userId      Int
  platformId  Int
  chatroomId  Int
  subject     String
  category    String?
  priority    String    @default("medium") // low | medium | high
  status      String    @default("open")   // open | in_progress | resolved | closed
  employeeId  Int?
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

model ChatRoomMessageToTicket {
  id        Int             @id @default(autoincrement())
  messageId Int
  ticketId  Int
  Message   ChatRoomMessage @relation(fields: [messageId], references: [id])
  Ticket    Ticket          @relation(fields: [ticketId], references: [id])
}
```

Migration/generate: **run manually by you after review** — `npx prisma migrate dev --name add_ticket_system` then `npx prisma generate`. Claude Code only edits the schema file, never runs prisma commands.

`ChatRoomMessageToTicket` ships now (single migration) but no code writes to it in Phase 1.

---

## 3. Routes — All in `../src/ticket/ticket.controller.ts`

Controller prefix: `@Controller('ticket')` (global `/api` prefix applies on top).

> **Route-ordering rule (critical):** declare all `command/*` routes **before** any `:ticketId` route in the controller, otherwise `queue`/`mine`/`stats` get swallowed by `GET :ticketId`.

### Employee routes — declare FIRST — `@UseGuards(EmployeeAuthGuard)`

| # | Method + Path | Permission | Logic |
|---|---|---|---|
| 1 | `GET /ticket/command/queue` | `canViewTickets` | Unassigned tickets: `status='open' AND employeeId=null`, current `platformId`, filter `category?`/`priority?`, paginated 20/page, newest first |
| 2 | `GET /ticket/command/mine` | `canViewTickets` | `employeeId = requesting employee`, filter `status?`, paginated |
| 3 | `GET /ticket/command/stats` | `canViewTickets` | `{ total, open, inProgress, resolved, closed }` for the platform — single `groupBy` on status |
| 4 | `GET /ticket/command/:ticketId` | `canViewTickets` | Case detail + ticket owner's user name. `404` if not found on this platform |
| 5 | `PATCH /ticket/command/:ticketId/claim` | `canManageTickets` | `$transaction`: `updateMany` guarded on `{ id, employeeId: null, status: 'open' }` setting `{ employeeId, status: 'in_progress' }` — if `count === 0` → `400 "Ticket already claimed or not open"` (copy the race-safe pattern from lead claiming in `../src/lead/lead.service.ts`). On success, create `ChatroomToEmployees` row for the ticket's `chatroomId` inside the same transaction |
| 6 | `PATCH /ticket/command/:ticketId/resolve` | `canManageTickets` | Must be the assigned employee (`403` otherwise). Only from `in_progress` (`400` otherwise). Set `status='resolved'`, `resolvedAt=now()` |
| 7 | `PATCH /ticket/command/:ticketId/close` | `canManageTickets` | Must be the assigned employee (`403`). Callable from `in_progress` **or** `resolved` (`400` otherwise). Set `status='closed'`, `closedAt=now()` |

### Student routes — declare AFTER — `@UseGuards(AuthGuard)`

| # | Method + Path | Logic |
|---|---|---|
| 8 | `POST /ticket` | Body = `CreateTicketDto` (`multipart/form-data`, one optional attachment via the same single-file interceptor pattern the chat composer routes use). Steps: (1) create `ChatRoom` `{ type: 'Ticket', platformId }` + `ChatroomToUsers` row for the student; (2) create `Ticket` row (`status='open'`, `chatroomId` from step 1); (3) call the **existing** `communicateService.sendMessage(userId, platformId, { roomId, message: description }, file, token)` so the description becomes message #1 in the room — **no `ticketIds` param (doesn't exist yet, Phase 2)**. Return the created ticket incl. `chatroomId` |
| 9 | `GET /ticket` | Student's own tickets (`userId` from auth), filter `status?`, paginated 20/page, newest first. Case metadata only — no messages |
| 10 | `GET /ticket/:ticketId` | Case detail. `403` if `ticket.userId !== requesting user`. `404` if not found |
| 11 | `PATCH /ticket/:ticketId/reopen` | Owner only (`403`). Only from `resolved`/`closed` (`400` if `open`/`in_progress`). Set `status = employeeId ? 'in_progress' : 'open'`; null out `resolvedAt`/`closedAt` |

---

## 4. Status Lifecycle (enforced in service)

```
open ──claim──▶ in_progress ──resolve──▶ resolved ──close──▶ closed
                    │                        │
                    └────────close───────────┘
closed/resolved ──reopen (student)──▶ in_progress (if employeeId set) | open (if not)
```

---

## 5. Edge Cases To Enforce

| Case | Response |
|---|---|
| Concurrent claim | `updateMany` guard — loser gets `400` |
| Resolve/close by non-assigned employee | `403` |
| Reopen while `open`/`in_progress` | `400` |
| Student views another student's ticket | `403` |
| Employee missing permission string | `403` |
| Resolve from any status other than `in_progress` | `400` |
| Close from `open` | `400` |

---

## 6. Deferred to Phase 2 (do NOT build now)

- `ticketIds?: number[]` on `SendMessageDto` + tagging loops in `sendMessage`/`sendEmployeeMessage`
- `new_ticket` socket event + `ticket_queue_${platformId}` room join in `employee.gateway.ts`
- `ticket_status_changed` socket event
- Closed-ticket reply blocking (if we decide to block at all)

---

## 7. Claude Code Prompt

Lives separately in `ticket-phase1-prompt.md` — paste that file's content into Claude Code as-is. It references this spec (§2 schema, §3 routes, §4 lifecycle, §5 edge cases), so both files must sit at the repo root.

---

## 8. Phase 2 (next prompt, later)

SendMessageDto `ticketIds` + tagging loops → socket events (`new_ticket`, `ticket_status_changed`, queue-room join) → closed-ticket reply decision. Separate prompt file when Phase 1 is merged.