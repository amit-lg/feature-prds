# Newsletter Campaign Management — Admin Frontend Requirements

Status: **Draft for review**. Companion to [`newsletter-campaign-feature.md`](./newsletter-campaign-feature.md)
(backend design) — every screen here binds to an endpoint defined there. This doc assumes no
existing admin UI for newsletters exists yet; if there's already a command/admin frontend repo
with shared components (data tables, modals, permission gating), those should be reused rather
than rebuilt — that repo wasn't in scope for this pass, so component reuse isn't assumed below.

## 1. Decisions made (confirmed with product owner)

| Question | Decision |
|---|---|
| Content authoring | Raw HTML textarea + a live preview pane that substitutes `{{fname}}`/`{{email}}`/etc. with sample data, alongside a separate Brevo `templateId` field. No WYSIWYG editor. |
| Subscriber management | View + search + select only. No manual add/edit/delete of subscribers in this UI — acquisition stays on the existing public `subscribeNewsLetter` flow. |
| Reporting depth | A simple send log (subscriber, step/blast, status, timestamp, error) — exactly what `EmailSend` tracks today. No opens/clicks/bounces (that needs a Brevo webhook, not yet designed). |
| Send safety | A "Send test" action (emails just the admin) before the real send, plus a confirmation modal showing exact recipient count and content preview before an actual blast fires. |

## 2. Audience & permissions

Actor: an `Employee`, authenticated via `EmployeeAuthGuard` (same as the rest of `/command`).
`BulkMessageModule`'s own code notes permission gating (`canSendMail`/`canSendWhatsApp`) was
"intentionally deferred" — this feature shouldn't repeat that gap. Two new permission strings,
following the existing `canSendMail`/`canManageTickets` naming convention in
`permissionsStrings.txt`:

- `canManageNewsletter` — create/edit/delete campaign flow steps (configuration, no sending).
- `canSendNewsletter` — trigger a manual blast and view send history (an admin could plausibly
  have one without the other, e.g. a marketer who drafts content but a lead who approves sends).

Both are checked via the existing recursive permission tree
(`EmployePermissionCheck.checkPermission` in `check-permission.ts`), same as every other
`/command` screen.

## 3. Information architecture

```
/command/newsletter
├── /campaigns                          — campaign list (grouped by campaignName)
│   └── /:campaignName
│       ├── /flow                       — flow step management for this campaign
│       ├── /subscribers                — browse/search/select subscribers
│       ├── /send                       — manual blast composer
│       └── /history                    — send log for this campaign (flow + manual)
```

Campaign list is the landing page; everything else is scoped under a `campaignName`, since flows
are per-campaign (per the backend design).

## 4. Screen requirements

### 4.1 Campaign list (`/newsletter/campaigns`)

Binds to `GET /newsletter/campaigns`.

- Table: campaign name, total subscribers, subscribed (active) count, number of active flow
  steps, last manual blast date (if any).
- Row click → campaign detail (`/newsletter/campaigns/:campaignName/flow` as the default tab).
- Search/filter by campaign name.
- No "create campaign" button — a `campaignName` comes into existence implicitly the first time
  a `NewsletterSubscriber` row uses it (set during signup) or the first time a flow step is
  created for it (see 4.2). Confirm this matches intent — if you want campaigns to be explicitly
  created/named up front (decoupled from signup-time strings), that's a bigger change to the
  backend model (§7, open question).

### 4.2 Flow step management (`/newsletter/campaigns/:campaignName/flow`)

Binds to `GET/POST/PATCH/DELETE /newsletter/flow-steps`. Requires `canManageNewsletter`.

- List of steps for this campaign, each showing: name, delay (`delayMinutes`, displayed as a
  human unit — e.g. an input that lets the admin pick "7" + "days" and the frontend converts to
  minutes), content type (Template vs HTML), `isActive` toggle, and a quick summary of send
  results so far (sent / failed / skipped counts, pulled from `/history` filtered by
  `flowStepId`).
- Since steps are **independent** (each fires at its own offset from `subscribedAt`, no
  dependency between steps — see backend doc §2), the list does not need drag-to-reorder; a
  simple sortable-by-delay list is sufficient. Flag if you actually want a visual sequence/timeline
  view instead — that's a materially bigger UI component.
- "Add step" opens the step editor (§4.4).
- Deactivating a step (`isActive: false`) rather than deleting is the primary action — deletion
  should be a secondary, confirm-gated action, since the backend keeps `EmailSend` history via
  `flowStepId` even after a step is edited, but a hard delete needs `onDelete: SetNull` to not
  break that history (per backend doc §6).

### 4.3 Subscribers (`/newsletter/campaigns/:campaignName/subscribers`)

Binds to `GET /newsletter/campaigns/:campaignName/subscribers`. View-only, no
create/edit/delete controls per the scope decision in §1.

- Table: resolved `fname` (from `fieldJson`, falling back to linked `User.fname`), `email`,
  `isSubscribed` status, subscribed date, linked-user indicator (whether `userId` is set — useful
  to distinguish "platform user" subscribers from "email-only" landing-page subscribers, since
  they're not the same population — see backend doc §4.1).
- Search by email/name, filter by subscribed/unsubscribed.
- Row checkboxes + "select all matching filter" → feeds directly into the manual blast composer
  (§4.4) as a `subscriberIds` payload, or the composer can instead target the whole campaign
  server-side (no explicit ID list) — both modes should be supported per the backend DTO shape.

### 4.4 Manual blast composer (`/newsletter/campaigns/:campaignName/send`)

Binds to `POST /newsletter/campaigns/send`. Requires `canSendNewsletter`.

Shared content editor (used here and in the flow step editor):

- Toggle: **Template** (Brevo `templateId` numeric input) vs **Custom HTML** (raw HTML textarea).
- If Custom HTML: `subject` field is required (per backend validation rule).
- Live preview pane: renders the HTML with `{{fname}}` → a sample name, `{{email}}` → a sample
  address, and any additional `{{key}}` tokens the admin has added to the "extra params" list (see
  below) substituted with the value they typed. Unresolved tokens should render visibly flagged
  (e.g. highlighted) in the preview, matching the backend's "leave unresolved rather than blank"
  behavior (backend doc §4.2) — an admin should be able to see a typo'd placeholder before sending.
- "Extra params" key/value list — free-form rows the admin adds (e.g. `promoCode` → `SAVE20`),
  applied uniformly to every recipient in this blast (per the confirmed decision — not
  per-recipient beyond the auto `fname`/`email`).

Recipient selection: either the explicit set carried over from §4.3, or "all subscribed users in
this campaign" (default, most common path — matches the original ask of "select all the users
which have subscribed for a campaign").

Send flow:
1. **"Send test"** button — sends the currently-composed content to the logged-in admin's own
   email only (not counted against real recipients), so they can sanity-check rendering and
   placeholder substitution in an actual inbox before committing.
2. **"Send to N subscribers"** button → confirmation modal showing: exact recipient count,
   subject/template id, and the same preview pane. Explicit confirm required.
3. On confirm → `POST /newsletter/campaigns/send`, navigate to a progress view showing live
   sent/failed/skipped/pending counts (via the `newsletter-blast-progress` socket event from the
   backend doc §6), with a link to the full log (§4.5) once complete.

### 4.5 Send history / log (`/newsletter/campaigns/:campaignName/history`)

Binds to a new `GET /newsletter/campaigns/:campaignName/history` endpoint (not yet in the backend
doc — add it: paginated `EmailSend` rows filtered by `subscriberId.campaignName`, joined to
subscriber email/fname for display). Requires `canSendNewsletter`.

- Table: recipient (email + resolved name), source (flow step name, or "Manual — {blastId}"),
  status, sent/attempted timestamp, error message (for `FAILED` rows, truncated with a
  view-full-error affordance).
- Filters: by status, by source (flow step vs manual blast, and which one), by date range.
- This is also where "which users have received emails" (the original ask) is answered directly —
  filter to a specific subscriber's email to see every send they've ever gotten across every step
  and blast in the campaign.
- Manual blasts should link back from the progress view (§4.4 step 3) into this table pre-filtered
  by `blastId`.

## 5. Cross-cutting requirements

- **Empty states**: a campaign with subscribers but no flow steps yet should show a clear
  "no automated emails configured — add a step" prompt on the flow tab, not a bare empty table.
- **Timezone display**: all timestamps (subscribed date, sent date) should render in the admin's
  local timezone client-side; the backend stores UTC.
- **Loading/error states** for every list/table (standard, not elaborated here).
- **No campaign-name typos**: since `campaignName` is a free-text string on `NewsletterSubscriber`
  with no enum/lookup table backing it, the campaign list (§4.1) should be the *only* place
  campaign names are discovered — never let an admin free-type a `campaignName` when creating a
  flow step; always select from existing values to avoid silently creating an orphaned,
  misspelled campaign that never matches real subscribers.

## 6. Instruction steps (admin user flows)

### 6.1 Set up a new drip sequence for an existing campaign

1. Go to **Newsletter → Campaigns**, find the campaign (it must already have at least one
   subscriber — campaigns aren't created standalone, per §4.1).
2. Open the campaign, go to the **Flow** tab.
3. Click **Add step**. Give it a name (e.g. "Day 7 check-in"), set the delay (e.g. 7 days after
   subscribing).
4. Choose content: either enter a Brevo **Template ID**, or switch to **Custom HTML** and paste
   HTML (use `{{fname}}` / `{{email}}` where personalization is needed).
5. Use the preview pane to confirm placeholders render correctly.
6. Save. The step is active by default — it will start firing for subscribers who cross the
   delay threshold on the next cron run (within ~15 minutes, per backend doc §5).
7. Repeat steps 3–6 for additional steps (e.g. a Day 1 welcome, a Week 1 follow-up, a Month 1
   nudge) — each fires independently, so order of creation doesn't matter.

### 6.2 See who's subscribed to a campaign

1. Go to the campaign's **Subscribers** tab.
2. Use search/filters (subscribed only, by name/email) as needed.
3. Each row shows whether the subscriber is a linked platform `User` or an email-only signup.

### 6.3 Send a one-off blast to everyone subscribed to a campaign

1. From the campaign, go to **Send**.
2. Leave recipient selection on "all subscribed users" (default), or go to **Subscribers** first
   and select a specific subset, then click **Send to selected**.
3. Compose content (template or HTML), add any extra params, check the preview.
4. Click **Send test** and check your own inbox.
5. Click **Send to N subscribers**, confirm the count in the modal, confirm.
6. Watch the live progress view; once complete, follow the link to the filtered history log to
   audit results.

### 6.4 Check who has received a specific email (flow step or blast)

1. Go to the campaign's **History** tab.
2. Filter by source (a specific flow step, or a specific past blast) and/or status.
3. To check one person specifically, filter by their email — this shows every send they've ever
   received in this campaign, across every step and blast.

## 7. Open questions

1. **Does a "campaign" need to be an explicit, creatable entity**, rather than an implicit string
   that only exists because a subscriber or flow step references it? Right now `campaignName` has
   no backing table — there's no place to set a campaign-level description, owner, or default
   sender identity. If you want that, it changes the backend model (a `NewsletterCampaign` table
   that `campaignName` becomes a real FK to) — flag this now since it affects §4.1's "campaigns
   are discovered, not created" assumption.
2. **`GET /newsletter/campaigns/:campaignName/history`** isn't in the backend doc yet — needs to
   be added there before or alongside frontend implementation.
3. **Permission split** (`canManageNewsletter` vs `canSendNewsletter`) is a recommendation based
   on the existing naming convention, not a confirmed decision — confirm before adding to
   `permissionsStrings.txt`.
