# Support Tickets — Student-Facing Frontend PRD

Status: Draft
Owner: TBD
Source: audit of the *implemented* code — `src/ticket/ticket.controller.ts`, `src/ticket/ticket.service.ts`, `src/ticket/dto/*`, `src/communicate/communicate.controller.ts`, `src/communicate/communicate.service.ts` (`sendMessage`, `generateAIResponseInChat`, `getTicketMessages`, `askAi`), `src/communicate/dto/send-message.dto.ts`, `src/communicate/dto/ask-ai.dto.ts`, `prisma/schema.prisma`, `src/user/user.gateway.ts`, `src/auth/auth.service.ts` (`wsLogin`), `permissionsStrings.txt`.
Related docs: `docs/ticket-system.md` (the original design doc — see §8 for every place the shipped code diverged from it), `docs/faq-admin.md` (a *different*, DB-backed FAQ system — see §6.1 for why it matters here), `docs/employee-communication.md`.

## 1. Summary

**Everything described in this PRD already exists server-side.** There is nothing left to build on the backend — this document exists purely so a student-facing frontend can consume the already-implemented API surface correctly. Don't scope backend work off this doc.

It's also important not to mentally model "tickets" as their own backend module. `src/ticket/` is a thin ~200-line case-tracking shim (create/list/detail/reopen for the student; claim/unclaim/reassign/resolve/close for the employee, exposed via `command.controller.ts`). Every ticket has a dedicated `ChatRoom` (`type: 'Ticket'`), and **the actual conversation — sending, listing, and replying to messages, the AI help-chat, typing indicators, realtime delivery — is implemented inside the existing chat module** (`src/communicate/`), as `ticketId`-aware branches bolted onto the same `sendMessage`/`getMessages`-style code paths that power regular chat. For the frontend, this means: build "Support" as an extension of whatever chat/messaging UI already exists in the app, not as an isolated feature area with its own screens wired to its own module. Only 4 thin endpoints are genuinely ticket-module (case metadata); every conversational endpoint below is a chat-module endpoint.

On top of that base design, **two separate flows create tickets**, and the student app has to support both:

1. **Direct ticket form** — `POST /ticket` (subject/category/priority/description). Case-only; goes straight to the "open" queue for a human.
2. **AI-first help chat** — `POST /communicate/ask-ai` (chat module). A student types a question into a chat box with no ticket in mind; the backend silently creates a `Ticket` (`status: 'with_ai'`), answers from a static knowledge base, and only escalates to the human queue (`status: 'open'`) if the AI decides it can't help. This is effectively today's real "raise an issue" entry point for anything conversational, and it is **not mentioned anywhere in `docs/ticket-system.md`** (the older design doc, written before this shipped).

Both flows converge on the same `Ticket` row and the same ticket-detail/thread UI, so the frontend should treat them as two doors into one screen, not two separate features.

## 2. Scope

**In scope** (frontend work; all backing APIs already exist)
- Raise a ticket (direct form) — ticket module
- AI help chat (auto-creates/escalates tickets) — chat module
- My Tickets list — ticket module
- Ticket detail + message thread (reading and replying) — chat module (with ticket module for case metadata)
- Reopen a resolved/closed ticket — ticket module
- Realtime status + message updates — chat module sockets

**Out of scope**
- Employee queue/claim/resolve/unclaim/reassign UI — already implemented server-side under `/command/ticket/*` (registered in `command.controller.ts`, not `ticket.controller.ts` as the design doc assumed); needs its own PRD if not already covered elsewhere.
- FAQ admin content management (`docs/faq-admin.md`) — separate system, see §6.1.
- Any backend/API changes — see §1; this is a consume-what-exists PRD. Gaps noted throughout (§3.1, §6) are flagged for awareness, not proposed as frontend-owned fixes.

## 3. The two entry points

### 3.1 Direct form (`POST /ticket`)

Student explicitly reports an issue: subject (required), description (required), category (optional free text), priority (optional, `low`/`medium`/`high`, default `medium`), one optional attachment. Ticket is created with `status: 'open'` and lands directly in the employee queue — no AI involved.

**Backend gap to design around:** `TicketService.create()` currently has the "post description as the first chat message" call **commented out**, and the uploaded attachment is accepted by Multer but never used. In the shipped code today, submitting this form creates a `Ticket` row with an **empty thread** — the description text the student typed is not saved as a message anywhere, and any attached file is silently dropped. Until this is fixed server-side, do not assume the ticket detail screen will show the description as message #1; either treat this as a blocking backend bug to raise before building against it, or have the frontend itself fire a follow-up `POST /communicate/message` with the description/attachment right after ticket creation succeeds (workaround, not a fix).

### 3.2 AI help chat (`POST /communicate/ask-ai`)

Student opens a general "Ask for help" chat (not tied to any ticket yet) and types a message, optionally with up to 5 images (5 MB each, field name `uploadedFiles`). Behavior depends on ticket state:

- **No ticket yet / ticket still `with_ai`**: a `Ticket` is created (or reused) with `status: 'with_ai'`, the message is answered by an LLM (Claude) constrained to a static knowledge base (see §6.1). The ticket stays invisible to the employee queue while in this state.
- **AI decides to escalate**: if the model's reply is flagged internally (a sentinel prefix stripped before it's ever shown to the student — the student never sees raw markup), the ticket's `status` flips to `open` and the student's socket is joined into the ticket's realtime room. The ticket now appears in the employee queue exactly like a directly-created one.
- **Ticket already claimed by an employee** (`ticket.employeeId` set): the AI is bypassed entirely — the message is forwarded straight into the normal human-reply pipeline (`sendMessage`). Practically, this means the frontend can point every message the student sends *while inside a ticket thread* at `ask-ai`, and the backend will do the right thing (answer via AI, or deliver to the human) depending on claim state — it does not need to switch endpoints based on ticket status.

**Backend gaps to design around:**
- The response body's `ticket` field is the **pre-update** ticket object — even when this call just flipped status to `open` server-side, the JSON response still reports the old status. Don't drive UI state (e.g., "you're now talking to a human") off `response.ticket.status`; either re-fetch `GET /ticket/:ticketId` after every AI reply, or drive escalation UI purely off the `ticket_status_changed` socket event (§5).
- There is no boolean in the response telling the frontend "this reply triggered an escalation" — infer it only from the status transition, not from anything in the AI's text (the AI is explicitly instructed never to claim it raised a ticket or contacted anyone).
- The route is typed against `SendMessageDto` in the controller, not the dedicated `AskAiDto` that already exists (`src/communicate/dto/ask-ai.dto.ts`) — and unlike other endpoints, this route has **no `ValidationPipe`/`transform` wrapper**, so `roomId`/`ticketId` are not auto-coerced from strings. Send them as real JSON numbers, not numeric strings, or they'll fail identity checks server-side.
- Attachment field name is `uploadedFiles` (plural, array, max 5) here vs. `uploadedFile` (singular) on `POST /ticket` and `POST /communicate/message` — a real inconsistency across the three endpoints the student app has to call; don't assume one field name works everywhere.

## 4. Status lifecycle (as implemented — differs from the design doc)

```
with_ai       — AI-only, invisible to employee queue (only reachable via ask-ai)
  ↓ AI escalates (student never sees this as a discrete "action")
open          — unassigned, sitting in the employee queue
  ↓ employee claims
in_progress   — actively being worked
  ↓ resolve                              ↓ close (skips resolved)
resolved      — awaiting student confirmation      closed — final
  ↓ close            ↓ reopen (student)
closed        — final                    in_progress or open (per §4.1)
```

`with_ai` is a real, persisted `status` value used by the code, but it is **not** part of the enum the student-list/employee-list query DTOs accept (`GetTicketsDto.status` is `@IsIn(['open','in_progress','resolved','closed'])`). This means:
- A student's "My Tickets" call with no `status` filter *will* include `with_ai` tickets (unfiltered `findMany`) — decide with product whether these should show in the list at all, and if so, what to label them (they may just be one-off AI chat sessions the student never intended as a "ticket").
- The frontend cannot filter *for* `with_ai` specifically via the status query param — it will be rejected by validation.

### 4.1 Reopen (`PATCH /ticket/:ticketId/reopen`)

Only valid from `resolved`/`closed` (400 otherwise). Goes back to `in_progress` if `employeeId` is still set, otherwise `open`.

## 5. Realtime — read this before wiring sockets

This is the part most likely to be built wrong by extrapolating from the generic chat system, so the specifics matter:

- **Event name**: `ticket_message_recieved` (not `new_message`, and note the misspelling — it's the actual wire event, not a typo to "fix" client-side).
- **Room name**: `ticket_room_${chatroomId}_${ticketId}` on the `/user` namespace.
- **This room is not auto-joined on login**, unlike the regular per-user rooms (`user_${userId}`, `platform_${platformId}`, `user_platform_${userId}_${platformId}` — all joined in `wsLogin`). There is no `chat_room_*`-style auto-join for tickets anywhere in the codebase. The **only** way a student's socket ends up in `ticket_room_${chatroomId}_${ticketId}` is:
  1. Calling `GET /communicate/ticket-messages/:roomId/:ticketId?page=0` — the join is a side effect of requesting page 0 specifically (later pages don't join), or
  2. The AI escalation path in `generateAIResponseInChat`, which joins the student's already-connected sockets at the moment it flips status to `open`.
- **Practical rule for the frontend**: every time the ticket detail screen is opened (or the socket reconnects), call the ticket-messages endpoint with `page=0` first, even if messages are already cached client-side — skipping this call means the client will silently miss all live replies for that session.
- **Message listing**: use `GET /communicate/ticket-messages/:roomId/:ticketId?page=` — not the generic `GET /communicate/messages/:roomId`. The dedicated endpoint is the one that (a) filters strictly to this ticket's tagged messages and (b) performs the room join in (1) above.
- `ticket_status_changed` — emitted to the same room name, to both `/user` and `/employee`, on claim/resolve/close/reopen. Payload: `{ ticketId, status, employeeId }`.
- `new_ticket` — `/employee` only, queue screen; not relevant to the student app.

```js
// after opening a ticket thread (or on reconnect):
await fetch(`/api/communicate/ticket-messages/${roomId}/${ticketId}?page=0`)
socket.on('ticket_message_recieved', (msg) => { /* append */ })
socket.on('ticket_status_changed', ({ status }) => { /* update badge; re-fetch ticket detail */ })
```

## 6. API Endpoints (student-facing)

All under global prefix `/api`. Auth: `AuthGuard` (`Authorization: Bearer <jwt>`).

| Endpoint | Notes |
|---|---|
| `POST /ticket` | multipart, `CreateTicketDto` (`subject`, `description` both required; `category`, `priority` optional). See §3.1 gap — description/attachment are currently dropped. |
| `GET /ticket?status=&category=&page=` | `GetTicketsDto`; `status` enum excludes `with_ai` (§4). `priority` filter is also accepted but note `getMyTickets` doesn't actually apply the `priority`/`category` filters server-side today (only `status` is used in the `where` clause) — confirm before shipping filter UI, or filter client-side. |
| `GET /ticket/:ticketId` | Case metadata only. **Does not include the assigned employee's name** (only raw `employeeId`) — if the UI needs "being handled by Alex", that's a backend addition; the employee-facing equivalent already does this join, the student one doesn't. |
| `PATCH /ticket/:ticketId/reopen` | 400 if not `resolved`/`closed`. |
| `POST /communicate/ask-ai` | multipart, fields per §3.2. |
| `GET /communicate/ticket-messages/:roomId/:ticketId?page=` | Thread + realtime join, see §5. |
| `POST /communicate/message` | `{ roomId, ticketId, message }` (multipart if attaching, field `uploadedFile`). 400 if `ticket.status === 'closed'` ("Cannot reply to a closed ticket. Reopen it first.") — this is already enforced server-side, resolving the open question the design doc left flagged. |
| `GET /communicate/typing/:roomId?status=&ticketId=` | Typing indicator scoped to the ticket room. |

## 6.1 Knowledge base powering the AI (flag to product)

`generateAIResponseInChat` reads a **static `knowledge.json` file bundled with the deployment** (`fs.readFileSync(path.join(process.cwd(), 'knowledge.json'))`), tokenized and keyword-scored in-process. This is a **completely separate system** from the DB-backed `FaqSubject`/`FaqQuestion` hierarchy documented in `docs/faq-admin.md` and managed through the admin panel. Today, updating what the AI chat can answer requires editing/redeploying `knowledge.json` — an admin editing FAQs through the documented FAQ admin UI has **no effect** on what this chat bot says. Surface this to product/ops before launch: either the two need to be unified, or admins need a documented (even if manual) path to update `knowledge.json`.

Also relevant to UI copy: the system prompt hard-bans the AI from ever surfacing contact details or claiming "I've raised a ticket" / "someone will follow up" — escalation is silent from the AI's own text. Any "connecting you to a human" messaging in the product must come from the frontend detecting the status transition (§5), not from parsing the AI's reply.

## 7. Cross-cutting frontend requirements

- **Treat `ask-ai` as the default send action inside a ticket thread** (§3.2) rather than branching client-side on ticket status — the backend already does that branching.
- **Don't trust the AI response's embedded `ticket` object for status** — always re-derive current status from `ticket_status_changed` or a fresh `GET /ticket/:ticketId` (§3.2).
- **Join the ticket socket room on every screen-open/reconnect**, not just once per session (§5) — there is no persistent server-side membership to fall back on.
- **Normalize attachment field names** across the three upload-capable endpoints (`uploadedFile` vs `uploadedFiles`) in one shared upload helper so screens don't each hardcode a different multipart shape.
- **Send numeric fields as JSON numbers on `ask-ai`** specifically (§3.2) — it's the one endpoint without automatic string→number coercion.

## 8. Where the shipped code diverged from `docs/ticket-system.md`

For anyone who read the design doc first:

1. Employee routes live at `/command/ticket/*` (in `command.controller.ts`), not `/ticket/command/*`.
2. Messages are tagged with a single `ticketId: number` field on `SendMessageDto`, not a `ticketIds: number[]` array as designed.
3. There's no generic reuse of `new_message` for ticket replies — a dedicated `ticket_message_recieved` event on a dedicated `ticket_room_*` room was built instead, and it is not auto-joined on login (§5) — the design doc explicitly flagged this as unverified; it's now confirmed **not** to auto-join.
4. The "student replies to a closed ticket" edge case the design doc left as an open question is resolved: it's blocked with a 400.
5. An entire AI-first ticket-creation path (§3.2, `with_ai` status, `ask-ai` endpoint, static knowledge base) exists and isn't mentioned in the design doc at all.
6. `unclaim` and `reassign` employee actions exist and aren't in the original design.
7. The description-as-first-message step from ticket creation is implemented in code but currently commented out (§3.1) — a live regression against the original design intent, not a deliberate change.

## 9. Suggested delivery order

1. My Tickets list + ticket detail (read-only) — validates auth, listing, and case-metadata rendering against real endpoints first.
2. Realtime wiring for an existing ticket thread (§5) — get the join-then-listen pattern right before building message composition, since it's the easiest part to get subtly wrong.
3. Reply composer + reopen action.
4. Direct "Raise a Ticket" form — flag the description/attachment gap (§3.1) to backend before or during this step; sequence it after step 2 so the thread UI it hands off to already exists.
5. AI help chat — depends on steps 1–3 (it hands off into the same thread UI) and a product decision on `with_ai` ticket visibility (§4).
