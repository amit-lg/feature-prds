# Newsletter Campaign Feature — Backend Design

Status: **Draft for review** — schema and API not yet implemented.

## 1. Summary

Add a drip-campaign engine on top of the existing `NewsletterSubscriber` table:

- A new **flow step** table defines, per `campaignName`, a sequence of timed emails
  ("N minutes/days after subscribing, send this template or HTML").
- A new **`EmailSend`** table is a generic log of every email the system sends, not just
  newsletter ones — nullable links to whichever entity triggered it (`NewsletterSubscriber`,
  `NewsletterCampaignFlowStep`, `User`, `Employee`), plus a `category` string. This feature only
  writes to it from the two new newsletter send paths (§3.1); other existing `EmailsService`
  methods keep working unlogged for now — see the retrofit note in §3.1.
- A cron job (consistent with `src/tasks/tasks.service.ts`) polls due steps and sends them.
- A manual "blast" API lets an employee pick a set of subscribed users (by campaign or by
  explicit selection) and send them a template or raw HTML with extra parameters, modeled
  on the existing `BulkMessageModule` flow in `command.service.ts` but with persisted
  history instead of in-memory-only progress.

## 2. Decisions made (confirmed with product owner)

| Question | Decision |
|---|---|
| Flow scope | Flows are **per-campaign**, keyed by `NewsletterSubscriber.campaignName`. A subscriber's flow is whichever steps exist for their `campaignName` (+ `platformId`). |
| Content priority | Each step may set `templateId` and/or `html`. If `templateId` is set, it is used (Brevo-hosted template via `sendBrevoMail`); `html` is the fallback when no `templateId` is set. |
| Scheduling | Cron polling, e.g. every 15 minutes, matching existing jobs in `tasks.service.ts`. `dueAt` is computed on the fly as `subscriber.createdAt + step.delayMinutes`, not precomputed. |
| Step ordering | Steps are **independent** — each fires at its own offset from `subscribedAt`, regardless of whether earlier steps succeeded. |
| Delivery tracking | All sends (automated + manual) are persisted in a generic `EmailSend` log (not newsletter-specific) — required for dedup, audit, and status, and reusable by other email types later. |
| Manual blast params | Each recipient gets `fname`/`email` auto-filled (resolved per-subscriber from `fieldJson`/`User`, see §4.1 — this isn't a flat value, since subscribers aren't always users); the sender additionally supplies a flat set of extra key/value params applied uniformly to every recipient in that blast (e.g. promo code, event date). |
| Unsubscribe handling | Every send — automated or manual — re-checks `isSubscribed = true` **at send time**, not just at enrollment/selection time. A mid-flow unsubscribe silently stops future sends. |

## 3. Data model additions

No Prisma `enum`s below — Postgres enums are a pain to evolve (adding/removing a value means an
`ALTER TYPE`, which can't run inside a transaction with other schema changes and has locking
gotchas). `category` and `status` are plain `String` columns instead, validated at the
application/DTO layer.

### 3.1 `EmailSend` is generic, not newsletter-specific

Rather than a `NewsletterSend` table hard-tied to `NewsletterSubscriber`, `EmailSend` is a
system-wide log: **every** email the app sends should eventually write one row here, whatever
triggered it. All the "who/what triggered this" columns are nullable, because most existing
email call sites (`sendVefificationEmail`, `sendWelcomeEmail`,
`sendEnrollmentConfirmationEmail`, `sendSelfCodeMail`, `sendIntrospectAnalysisMail` in
`email.service.ts`) target a `User`, not a `NewsletterSubscriber`.

**Scope of this feature**: only the two new newsletter send paths (automated flow steps, §5;
manual blasts, §6) write to `EmailSend` right now. The existing methods above are left as-is —
retrofitting them to also log is a separate follow-up (see open question in §7), not part of
this change, so their call sites don't need to change today.

`category` values used by this feature: `'NEWSLETTER_FLOW' | 'NEWSLETTER_MANUAL'`. The column is
a free-form string specifically so future retrofits can add `'VERIFICATION'`,
`'PAYMENT_CONFIRMATION'`, `'WELCOME'`, etc. without a migration.

`status` values: `'PENDING' | 'SENT' | 'FAILED' | 'SKIPPED'` (`SKIPPED` e.g. subscriber
unsubscribed before send time).

```prisma
model NewsletterCampaignFlowStep {
  id           Int       @id @default(autoincrement())
  campaignName String
  platformId   Int?
  Platform     Platform? @relation(fields: [platformId], references: [id])
  name         String    // internal label, e.g. "Day 7 follow-up"
  delayMinutes Int       // offset from NewsletterSubscriber.createdAt
  templateId   Int?      // Brevo template id — takes priority when set
  subject      String?   // required when html is used (Brevo templates carry their own subject)
  html         String?   // raw HTML with {{fname}} / {{email}} placeholders
  isActive     Boolean   @default(true)
  createdAt    DateTime  @default(now())
  updatedAt    DateTime  @updatedAt
  EmailSends   EmailSend[]

  @@index([campaignName, platformId, isActive])
}

model EmailSend {
  id            Int                         @id @default(autoincrement())
  recipientEmail String                     // always set, regardless of what else is linked
  category      String                      // 'NEWSLETTER_FLOW' | 'NEWSLETTER_MANUAL' | ...future
  status        String                      @default("PENDING") // 'PENDING' | 'SENT' | 'FAILED' | 'SKIPPED'

  // Nullable links to whatever triggered this send — populate whichever apply, leave the rest null.
  userId        Int?
  User          User?                       @relation(fields: [userId], references: [id])
  employeeId    Int?
  Employee      Employee?                   @relation(fields: [employeeId], references: [id])
  subscriberId  Int?
  Subscriber    NewsletterSubscriber?       @relation(fields: [subscriberId], references: [id])
  flowStepId    Int?
  FlowStep      NewsletterCampaignFlowStep? @relation(fields: [flowStepId], references: [id])

  blastId       String?                     // groups one manual blast's sends together
  templateId    Int?
  subject       String?
  paramsJson    Json?                       // resolved params actually used, for audit
  errorMessage  String?
  sentAt        DateTime?
  createdAt     DateTime                    @default(now())
  updatedAt     DateTime                    @updatedAt

  // Postgres unique constraints treat a row as distinct if ANY column is NULL, so this only
  // blocks true duplicates — a subscriber getting the same flow step twice — while leaving
  // every other category (subscriberId/flowStepId null, or only userId set) unconstrained.
  @@unique([subscriberId, flowStepId])
  @@index([blastId])
  @@index([category, status])
  @@index([recipientEmail])
}
```

Also add the inverse relations on the existing models:

```prisma
model NewsletterSubscriber {
  // ...existing fields...
  EmailSends EmailSend[]
}

model User {
  // ...existing fields...
  EmailSends EmailSend[]
}

model Employee {
  // ...existing fields...
  EmailSends EmailSend[]
}
```

And on `Platform`:

```prisma
model Platform {
  // ...existing fields...
  NewsletterFlowSteps NewsletterCampaignFlowStep[]
}
```

## 4. Content resolution & placeholders

### 4.1 `NewsletterSubscriber` is not always a `User`

`userId` is optional, and the only field a subscriber is guaranteed to have is `email` —
`subscribeNewsLetter` today creates rows with just `email` / `platformId` / `userId`, no
`fieldJson`. That means:

- A subscriber captured from a standalone landing page / lead magnet may have **no linked
  `User` row at all**, so `User.fname` is not a reliable source of the recipient's name.
- `fieldJson` is the intended place to carry whatever extra data was captured at signup time
  (name, phone, source, etc.) for subscribers who aren't full platform users. It's currently
  unused by `subscribeNewsLetter`, so the signup endpoint(s) need to start populating it
  (e.g. `{ fname: '...' }`, or richer, per campaign) as part of this feature — otherwise the
  "N.fname" personalization has nothing to read for non-user subscribers.

Per-subscriber field resolution, used to build `params` for both flow steps and manual blasts:

```ts
function resolveSubscriberFields(subscriber: NewsletterSubscriber & { User?: User | null }) {
  const extra = (subscriber.fieldJson ?? {}) as Record<string, unknown>;
  return {
    email: subscriber.email, // always from the subscriber row, never User.email
    fname: (extra.fname as string) ?? subscriber.User?.fname ?? '',
    ...extra, // any other captured field (phone, city, source...) becomes a usable placeholder
  };
}
```

`fieldJson` wins over `User.fname` when both exist, since `fieldJson` reflects what was
captured specifically for this subscription/campaign and may be more current or more relevant
than the account's profile name. This means the cron job's subscriber query (§5) and the manual
blast recipient query (§6) both need to `select`/`include` `fieldJson` and `User: { select: { fname: true } }`,
not just `email`.

### 4.2 Sending

Resolution order per step/send:

1. If `templateId` is set → send via Brevo hosted template (`EmailsService.sendBrevoMail`), passing
   `params = { ...resolveSubscriberFields(subscriber), ...extraParams }`. Brevo does the substitution.
2. Else → send raw `html` via a new `EmailsService.sendCustomNewsletterMail(...)` method
   (same shape as the existing `sendIntrospectAnalysisMail`, which already sets `htmlContent`
   directly on `SendSmtpEmail`), after substituting placeholders server-side with the same
   resolved field map.

Either path creates a `PENDING` `EmailSend` row first (`category: 'NEWSLETTER_FLOW'` or
`'NEWSLETTER_MANUAL'`, `subscriberId` + `flowStepId` set as applicable), then updates it to
`SENT`/`FAILED` after the provider call resolves.

Placeholder syntax in raw HTML: `{{fname}}` and `{{email}}` are always available; any other key
present in a given subscriber's `fieldJson`, or supplied as an extra param on a manual blast
(e.g. `{{promoCode}}`), is usable the same way. A small utility does a literal `String.replace`
per key — no template engine dependency needed:

```ts
function applyPlaceholders(html: string, data: Record<string, string>): string {
  return Object.entries(data).reduce(
    (out, [key, value]) => out.replaceAll(`{{${key}}}`, String(value ?? '')),
    html,
  );
}
```

Unresolved placeholders (a token in the HTML with no matching key in `data`) are left as-is
rather than silently blanked, so a bad template is visibly broken instead of shipping
`Hi ,` — worth catching in a preview/test-send step before activating a flow step.

## 5. Automated flow scheduling

New provider, e.g. `src/newsletter/newsletter-flow.cron.ts`, registered like other jobs in
`tasks.service.ts`:

```
@Cron('0 */15 * * * *') // every 15 minutes
async processNewsletterFlowSteps() {
  const steps = await this.db.newsletterCampaignFlowStep.findMany({ where: { isActive: true } });

  for (const step of steps) {
    const dueBefore = new Date(Date.now() - step.delayMinutes * 60_000);

    const dueSubscribers = await this.db.newsletterSubscriber.findMany({
      where: {
        campaignName: step.campaignName,
        platformId: step.platformId ?? undefined,
        isSubscribed: true,
        createdAt: { lte: dueBefore },
        EmailSends: { none: { flowStepId: step.id } }, // not yet sent this step
      },
      include: { User: { select: { fname: true } } }, // fieldJson is a plain column, included by default
      take: 200, // cap work per tick; remainder picked up next tick
    });

    for (const subscriber of dueSubscribers) {
      await this.sendFlowStep(subscriber, step); // creates PENDING row, sends, updates to SENT/FAILED
      await sleep(300); // basic provider rate-limit courtesy delay
    }
  }
}
```

Key properties:
- Re-checks `isSubscribed: true` right in the query, so unsubscribes are respected automatically.
- `EmailSends: { none: { flowStepId: step.id } }` plus the `@@unique([subscriberId, flowStepId])`
  constraint gives idempotency even if two cron ticks overlap (the second insert fails/short-circuits).
- `take: 200` bounds a single tick's work; large backlogs drain over multiple ticks rather than
  blocking the cron thread.

## 6. Manual campaign blast

Mirrors `CommandService.startBulkSend` in shape (`requestId`/progress, delay-based loop, socket
progress events to the employee room) but persists every send to `EmailSend` with
`category: 'NEWSLETTER_MANUAL'` and a shared `blastId`, instead of only holding progress in memory.

Suggested endpoints (guarded by `EmployeeAuthGuard` + `PlatformCheckMiddleware`):

| Method | Path | Purpose |
|---|---|---|
| GET | `/newsletter/campaigns` | List distinct `campaignName` values with subscriber counts, for the selection UI. |
| GET | `/newsletter/campaigns/:campaignName/subscribers` | List subscribers in a campaign (search/paginate) for manual selection. Must return `fieldJson` (or at least a resolved `fname`) alongside `email`, since many rows have no linked `User` to fall back on for display. |
| POST | `/newsletter/campaigns/send` | Start a blast: `{ subscriberIds?: number[], campaignName?: string, templateId?: number, subject?: string, html?: string, params?: Record<string,string> }`. Returns `{ blastId, total }`. |
| GET | `/newsletter/campaigns/send/:blastId/status` | Poll aggregate status (`sent`/`failed`/`skipped`/`pending`), backed by counting `EmailSend` rows for that `blastId`. |
| — | (socket) `employee_{id}` room, event `newsletter-blast-progress` | Live progress, same pattern as `bulk-message-progress`. |

Flow config CRUD (same guard):

| Method | Path | Purpose |
|---|---|---|
| POST | `/newsletter/flow-steps` | Create a step (`campaignName`, `name`, `delayMinutes`, `templateId?`, `subject?`, `html?`). |
| GET | `/newsletter/flow-steps?campaignName=` | List steps for a campaign. |
| PATCH | `/newsletter/flow-steps/:id` | Edit delay/content/`isActive`. |
| DELETE | `/newsletter/flow-steps/:id` | Remove a step (existing `EmailSend` history is kept — `flowStepId` FK should be `onDelete: SetNull` or the step should be soft-deleted via `isActive` instead of hard-deleted). |

DTO validation rule for both flow steps and manual blasts: **at least one of `templateId` or
`html` must be present**; if `html` is present without `templateId`, `subject` is required
(Brevo templates carry their own subject line, raw HTML sends do not).

## 7. Open questions still needing a decision before implementation

These weren't blocking enough to hold up the design doc, but need an answer before coding:

1. **Who populates `fieldJson` at subscribe time, and with what shape?** `subscribeNewsLetter`
   (`platform.service.ts`) currently only writes `email`/`platformId`/`userId` — `fieldJson` is
   never set. For non-user subscribers to get a personalized `fname` (or any other placeholder),
   either the public subscribe endpoint needs a new optional payload (e.g. `{ fname, ...custom }`)
   written into `fieldJson`, or an admin-side "add subscriber" flow needs one. Also: is `fieldJson`'s
   shape free-form per campaign, or should it follow a fixed set of keys (`fname`, `phone`, ...)
   the frontend always sends? A free-form shape is more flexible but means flow-step/blast authors
   can reference a placeholder key that happens to not exist for some subscribers (handled today by
   leaving the token unresolved, per §4.2 — confirm that's acceptable rather than skipping the send).
2. **Sender identity.** Existing code hardcodes sender email/name per call-site (e.g.
   `'mentor@newsletter.aswinibajaj.com'`). `Platform` has no `senderEmail`/`senderName` field today.
   Should the manual-send DTO accept `senderEmail`/`senderName` explicitly, should it come from a
   new `PlatformOptions` entry, or should flow steps also store their own sender identity?
3. **Unsubscribe link / compliance.** Raw HTML sends currently have no enforced unsubscribe
   footer. Do you want a mandatory `{{unsubscribeLink}}` placeholder auto-injected (with a token
   tied to `NewsletterSubscriber.id`) for CAN-SPAM/GDPR compliance, or is that handled elsewhere?
4. **Retry policy for `FAILED` sends.** Should the cron job retry a failed flow-step send on the
   next tick (bounded by attempt count), or is a failure terminal and left for manual re-trigger?
5. **Brevo rate limits.** What's an acceptable delay between sends in the cron loop and the manual
   blast loop? `BulkMessageModule` defaults to `delayMs: 2000`; is that fine to reuse here, or does
   this need to be configurable per blast the way the bulk-message DTO already allows?
6. **Retrofitting existing `EmailsService` methods onto `EmailSend`.** Deferred out of this
   feature's scope (§3.1) — when that follow-up happens, decide the `category` taxonomy up front
   (e.g. `'VERIFICATION'`, `'WELCOME'`, `'PAYMENT_CONFIRMATION'`, `'ENROLLMENT_CONFIRMATION'`,
   `'QUIZ_SELF_CODE'`) so it's consistent rather than ad hoc per call-site.

## 8. Suggested implementation order

1. Prisma schema migration (§3), regenerate client.
2. `EmailsService.sendCustomNewsletterMail` + `applyPlaceholders` util (§4).
3. `NewsletterModule` with flow-step CRUD (§6, second table) — no sending yet.
4. Cron job for automated flow sends (§5), tested against a short `delayMinutes` in a dev campaign.
5. Manual blast endpoints + socket progress (§6, first table), reusing the `BulkMessageModule`
   send-loop pattern but writing to `EmailSend`.
6. Resolve §7 open questions and wire in sender identity + (optionally) unsubscribe link injection.
