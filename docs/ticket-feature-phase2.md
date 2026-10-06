# Ticket Feature — Phase 2: Communicate Integration + Real-Time

> **Prerequisite:** Phase 1 merged, `prisma migrate dev` run, Prisma Client has `Ticket` + `ChatRoomMessageToTicket` types.  
> **Scope:** Wire ticket message tagging into the communicate service; add closed-ticket reply blocking; emit two new socket events; join employee queue room on connect.

---

## 1. Files To Touch

| File | Action | What changes |
|---|---|---|
| `../src/communicate/dto/send-message.dto.ts` | **Edit** | Add `ticketIds?: number[]` field |
| `../src/communicate/communicate.service.ts` | **Edit** | (a) tagging loop in `sendMessage` + `sendEmployeeMessage`; (b) closed-ticket block in both |
| `../src/ticket/ticket.service.ts` | **Edit** | Emit `new_ticket` on create; emit `ticket_status_changed` on claim/resolve/close/reopen |
| `../src/ticket/ticket.module.ts` | **Edit** | Import whatever module exports the employee + user gateways so the ticket service can inject them |
| `../src/employee/employee.gateway.ts` | **Edit** | On `handleConnection`: if employee has `canViewTickets`, join `ticket_queue_${platformId}` |

**Files explicitly NOT touched:** any controller, any other service, schema (already done), any DTO other than `send-message.dto.ts`.

---

## 2. `SendMessageDto` Change

`../src/communicate/dto/send-message.dto.ts` — add one field next to `practiceIds`/`mockIds`/`lectureIds`:

```ts
@IsOptional()
@IsArray()
@Type(() => Number)
ticketIds?: number[];
```

---

## 3. Communicate Service Changes

Both `sendMessage` (student) and `sendEmployeeMessage` (employee) in `../src/communicate/communicate.service.ts` get **two additions** each. Read the existing `practiceIds` loop first — both additions mirror the same pattern/position.

### 3a. Closed-Ticket Reply Block

Add **before** the `ChatRoomMessage` is created (early return, no side-effects):

```ts
if (dto.ticketIds?.length) {
  const closed = await this.databaseService.ticket.findFirst({
    where: { id: { in: dto.ticketIds }, chatroomId: dto.roomId, status: 'closed' },
  });
  if (closed) {
    throw new BadRequestException('Cannot reply to a closed ticket. Reopen it first.');
  }
}
```

Apply in both `sendMessage` and `sendEmployeeMessage`.

### 3b. Message Tagging Loop

Add **after** the `ChatRoomMessage` row is created, mirroring the existing `practiceIds` block verbatim — just swap the table and field name:

```ts
if (dto.ticketIds?.length) {
  for (const ticketId of dto.ticketIds) {
    await this.databaseService.chatRoomMessageToTicket.create({
      data: { ticketId, messageId: chatRoomMessage.id },
    });
  }
}
```

Apply in both `sendMessage` and `sendEmployeeMessage`.

---

## 4. Socket Events

### 4a. Two New Events

| Event | Namespace | Room | Payload | Trigger |
|---|---|---|---|---|
| `new_ticket` | `/employee` | `ticket_queue_${platformId}` | full ticket object | ticket created (`POST /ticket`) |
| `ticket_status_changed` | `/user` + `/employee` | `chat_room_${chatroomId}` | `{ ticketId, status, employeeId }` | claim / resolve / close / reopen |

These are emitted **from `ticket.service.ts`** — the service needs the gateway server reference to do so.

### 4b. How to Emit from the Ticket Service

Find how other services (e.g. `communicate.service.ts` or any service that emits socket events) get access to the gateway's `@WebSocketServer()` instance. Copy that exact injection pattern — do not invent a new one. Common patterns in this codebase:

- Direct gateway injection: `constructor(private readonly employeeGateway: EmployeeGateway)` → use `employeeGateway.server.to(...).emit(...)`
- Shared events service: inject and call it

Read the actual code first, identify the pattern, then replicate.

### 4c. Employee Queue Room Join

`../src/employee/employee.gateway.ts` → `handleConnection`:

After the existing `joinEmployeeChatRooms(client, employeeId)` call, add:

```ts
const hasTicketPerm = await this.employeeService.hasPermission(employeeId, 'canViewTickets');
if (hasTicketPerm) {
  const employee = await this.databaseService.employee.findUnique({
    where: { id: employeeId },
    select: { platformId: true },
  });
  if (employee) {
    client.join(`ticket_queue_${employee.platformId}`);
  }
}
```

> Check how `hasPermission` (or equivalent) is called in `employee.gateway.ts` already — if no direct permission helper exists on `EmployeeService`, look at how `EmployePermissionCheck.checkPermission` works and replicate the minimal check needed here. Do not use the full HTTP-context guard — this is a WS connection context.

---

## 5. Emit Points in `ticket.service.ts`

| Method | Event | When |
|---|---|---|
| `createTicket` | `new_ticket` | After ticket + room + first message created; emit to `ticket_queue_${platformId}` on `/employee` namespace |
| `claimTicket` | `ticket_status_changed` | After transaction commits; emit to `chat_room_${chatroomId}` on both `/user` + `/employee` |
| `resolveTicket` | `ticket_status_changed` | After update; emit to `chat_room_${chatroomId}` on both namespaces |
| `closeTicket` | `ticket_status_changed` | After update; emit to `chat_room_${chatroomId}` on both namespaces |
| `reopenTicket` | `ticket_status_changed` | After update; emit to `chat_room_${chatroomId}` on both namespaces |

Payload for `ticket_status_changed`:
```ts
{ ticketId: number, status: string, employeeId: number | null }
```

Payload for `new_ticket`: full ticket row (same shape as `POST /ticket` response).

---

## 6. Edge Cases

| Case | Behaviour |
|---|---|
| Student sends message to closed ticket room | `400 "Cannot reply to a closed ticket. Reopen it first."` — blocked before message is created |
| Employee sends message to closed ticket room | Same `400` (same block in `sendEmployeeMessage`) |
| `ticketIds` not provided (regular chat message) | Block + tagging loop both skip entirely — no change to normal chat behaviour |
| `ticketIds` provided but ticket not found | Tagging `create` will throw FK violation — let it bubble as `500` or catch + `400`; decide on implementation |
| Employee connects without `canViewTickets` | Does not join `ticket_queue_*` room — no event received |

---

## 7. Deferred to Phase 3 / Out of Scope

- Frontend integration
- Android (Callify) ticket support
- Ticket search / bulk operations
- SLA timers / escalation