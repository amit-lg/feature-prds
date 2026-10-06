# Lead Query Filter & Bulk Assign API

Advanced lead search using composable AND / OR filter groups, plus a bulk action to assign the matched (or explicitly selected) leads to a lead source in one call.

Covers two endpoints:

| Endpoint | Purpose |
|----------|---------|
| `POST /all-leads-filter` | Query leads based on when specific lifecycle events occurred — lead creation, payment, interaction, contact form submission, cart creation, or new user signup — with arbitrary date ranges, status filters, UTM parameters, negation, and logical combinations. |
| `POST /bulk-assign-lead-source` | Assign selected leads (by ID, or "select all" via the same filter) to a lead source. |

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

```
Authorization: Bearer <employee_token>
```

**Required permission:** `canViewAllLeads` for `/all-leads-filter`, `canViewEmployeeToLeadSources` for `/bulk-assign-lead-source`.
If the employee does not have the relevant permission, the server responds with `403 Forbidden`.

---

## Base URL

```
/api/command
```

---

## Concepts

### Filter types

Each condition targets one kind of event on a lead's lifecycle.

| `type` | What it matches |
|--------|-----------------|
| `LEAD_CREATED` | The date the `UserLead` record was created (`UserLead.createdAt`) |
| `PAYMENT_DONE` | A payment activity (`UserLeadActivity` where `paymentId` is set). Defaults to `status = "success"` if no `status` is supplied. |
| `INTERACTION` | A call / interaction activity (`UserLeadActivity` where `interactionId` is set) |
| `CONTACT_FORM` | A contact-form submission activity (`UserLeadActivity` where `contactFormId` is set) |
| `CART_CREATED` | A cart activity (`UserLeadActivity` where `cartId` is set) |
| `NEW_SIGNUP` | Leads that have a linked user account (`UserLead.userId` is set — the lead signed up) |

Activity-based types (`PAYMENT_DONE`, `INTERACTION`, `CONTACT_FORM`, `CART_CREATED`) are matched against `UserLeadActivity.createdAt` — the moment the activity was recorded.

### Dates

`dateFrom` and `dateTo` are inclusive. Both are normalised server-side to the **start and end of the day in IST** (Asia/Kolkata), so you can pass bare date strings (`"2025-08-15"`) without worrying about time components.

### Operators

| Operator | Behaviour |
|----------|-----------|
| `AND` | All conditions / groups must match |
| `OR` | At least one condition / group must match |
| `NOT` | **None** of the conditions / groups may match |

There are two levels of composition:

- **Group-level `operator`** — connects the `conditions` within a single group (`FilterGroupDto.operator`). Set to `"NOT"` to mean "none of this group's conditions match".
- **Top-level `operator`** — connects the `groups` with each other (`LeadQueryFilterDto.operator`). Set to `"NOT"` to mean "none of the groups match".

`NOT` here is a group/whole-request combinator, distinct from the per-condition `negate: true` flag (see [Negation (NOT) filters](#negation-not-filters) below) — use `negate` to invert one specific condition inside an otherwise AND/OR group, and use `operator: "NOT"` to invert an entire group or the whole set of groups at once. They compose freely (a `NOT` group can contain conditions that also have their own `negate: true`).

---

## Query leads with filter

```
POST /api/command/all-leads-filter
Content-Type: application/json
```

### Request body

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `operator` | `"AND"` \| `"OR"` \| `"NOT"` | **Yes** | How to combine the groups. `NOT` = none of the groups may match. |
| `groups` | `FilterGroup[]` | **Yes** | One or more filter groups |
| `page` | integer | No | 0-indexed page number. Page size fixed at **50**. Defaults to `0`. |
| `platformId` | integer | No | Filter leads belonging to a specific platform. Note: the response is always scoped to the caller's own platform regardless of this value — see [How it maps to the database](#how-it-maps-to-the-database). |
| `firstSourceIds` | integer[] | No | Filter by one or more **first-touch** lead source IDs (`UserLead.firstSourceId`) — where the lead originally came from. |
| `sourceIds` | integer[] | No | Filter by one or more **current** lead source IDs (`UserLead.sourceId`) — where the lead is presently assigned (this changes on re-assignment, e.g. via bulk-assign below; `firstSourceId` never does). |

#### `FilterGroup`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `operator` | `"AND"` \| `"OR"` \| `"NOT"` | **Yes** | How to combine the conditions within this group. `NOT` = none of the conditions may match. |
| `conditions` | `FilterCondition[]` | **Yes** | One or more conditions |

#### `FilterCondition`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `FilterType` | **Yes** | See [Filter types](#filter-types) above |
| `dateFrom` | ISO date string | No | Start of date range, inclusive. Normalised to `00:00:00 IST`. |
| `dateTo` | ISO date string | No | End of date range, inclusive. Normalised to `23:59:59 IST`. |
| `status` | string | No | **PAYMENT_DONE** — filter by payment status (`"success"`, `"pending"`, `"cancelled"`, `"awaited"`); defaults to `"success"` when omitted. |
| `slug` | string | No | **CONTACT_FORM** — filter by the contact form's slug (e.g. `"demo-request"`). |
| `platformId` | integer | No | **NEW_SIGNUP / LEAD_CREATED** — filter by the platform the signup or lead belongs to. Overrides the top-level `platformId` for this condition only. |
| `utms` | `Record<string, string>` | No | Filter by UTM parameters. For activity-based types (`PAYMENT_DONE`, `INTERACTION`, `CONTACT_FORM`, `CART_CREATED`) these are matched against `UserLeadActivity.utmFields`. For lead-level types (`LEAD_CREATED`, `NEW_SIGNUP`) they are matched against `UserLead.UTMs`. All supplied key-value pairs must match (AND). Example: `{ "utm_source": "google", "utm_medium": "cpc" }` |
| `statusId` | integer | No | Filter by lead status. **Hierarchical** — passing a parent status ID automatically includes all its descendant status IDs. For `INTERACTION` this matches `UserLeadInteraction.leadStatusId` (the status logged on the call). For all other types it matches `UserLead.statusId` (the lead's current status). |
| `employeeIds` | integer[] | No | **INTERACTION only.** Restrict to interactions logged by these employee IDs. Combine with `negate: true` to find leads a specific employee did *not* talk to. |
| `negate` | boolean | No | If `true`, matches leads that do **NOT** satisfy this condition, instead of ones that do. See [Negation filters](#negation-not-filters) below. |

### Negation (NOT) filters

Every condition can be inverted with `negate: true` — useful for "leads where X *didn't* happen" queries that the positive-only conditions above can't express directly.

**"Leads where payment didn't happen"** — no successful payment recorded at all:

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        { "type": "PAYMENT_DONE", "negate": true }
      ]
    }
  ]
}
```

Add `dateFrom`/`dateTo` to scope it to "no successful payment activity *in this window*" rather than "never paid, ever":

```json
{ "type": "PAYMENT_DONE", "dateFrom": "2026-05-01", "dateTo": "2026-05-31", "negate": true }
```

**"Leads this employee did NOT talk to between two dates"** — combine `employeeIds` + a date range + `negate`:

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "employeeIds": [42],
          "dateFrom": "2026-05-07",
          "dateTo": "2026-05-08",
          "negate": true
        }
      ]
    }
  ]
}
```

This returns leads with **no** interaction by employee `42` between 7 May and 8 May 2026 — regardless of whether other employees talked to them in that window, or whether employee 42 talked to them at some other time.

`negate` works on any `type`, e.g. `NEW_SIGNUP` + `negate: true` = leads with no linked user account (haven't signed up), `CONTACT_FORM` + `negate: true` = leads that never submitted that form.

### `NOT` as a group / top-level operator

Use `negate: true` to invert a single condition. Use `operator: "NOT"` on a **group** or on the **top level** when you want "none of several conditions/groups" in one shot, instead of negating each one individually.

**Group-level `NOT`** — leads that had **neither** a successful payment **nor** an interaction with employee `42`, both checked in May 2026 (equivalent to negating each condition and ANDing the results, but expressed as one negated group):

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "NOT",
      "conditions": [
        { "type": "PAYMENT_DONE", "dateFrom": "2026-05-01", "dateTo": "2026-05-31" },
        { "type": "INTERACTION", "employeeIds": [42], "dateFrom": "2026-05-01", "dateTo": "2026-05-31" }
      ]
    }
  ]
}
```

**Top-level `NOT`** — leads that don't match *any* of several scenarios (e.g. exclude anyone who either came from a specific campaign, or already submitted the demo form):

```json
POST /api/command/all-leads-filter

{
  "operator": "NOT",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        { "type": "LEAD_CREATED", "utms": { "utm_campaign": "summer-sale" } }
      ]
    },
    {
      "operator": "AND",
      "conditions": [
        { "type": "CONTACT_FORM", "slug": "demo-request" }
      ]
    }
  ]
}
```

### Response

```json
{
  "leads": [ ... ],
  "total": 120,
  "page": 0
}
```

| Field | Description |
|-------|-------------|
| `leads` | Array of `UserLead` objects for this page (max 50). Each lead includes `LeadSource`, `FirstSource`, `LeadStatus`, `Employee` (assigned), and `UserActivity` (with `Payment`, `Cart`, `ContactForm`, `Interaction → Employee`). |
| `total` | Total count across all pages matching the filter. |
| `page` | The page that was returned. |

---

## Examples

### Lead created on a specific date AND payment completed on another date

Finds leads that arrived on 15 Aug 2025 **and** made a successful payment on 17 Aug 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "LEAD_CREATED",
          "dateFrom": "2025-08-15",
          "dateTo": "2025-08-15"
        },
        {
          "type": "PAYMENT_DONE",
          "dateFrom": "2025-08-17",
          "dateTo": "2025-08-17"
        }
      ]
    }
  ]
}
```

---

### Filter interactions by status ID

Finds leads that had an interaction logged with status `5` (or any of its child statuses) in September 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "statusId": 5
        }
      ]
    }
  ]
}
```

---

### Filter payments by status

Finds leads with a **pending** payment in August 2025 (override the default `"success"` status).

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "PAYMENT_DONE",
          "dateFrom": "2025-08-01",
          "dateTo": "2025-08-31",
          "status": "pending"
        }
      ]
    }
  ]
}
```

---

### Filter contact form submissions by slug

Finds leads that submitted the `"demo-request"` form in September 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "CONTACT_FORM",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "slug": "demo-request"
        }
      ]
    }
  ]
}
```

---

### New signups on a specific platform

Finds leads that created a user account on platform `3` in August 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "NEW_SIGNUP",
          "dateFrom": "2025-08-01",
          "dateTo": "2025-08-31",
          "platformId": 3
        }
      ]
    }
  ]
}
```

---

### Filter by current lead source

`sourceIds` (top-level, alongside `firstSourceIds`) filters by the lead's **current** source (`UserLead.sourceId`), not where it originally came from. Finds leads currently assigned to source `12` or `18`:

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        { "type": "LEAD_CREATED" }
      ]
    }
  ],
  "sourceIds": [12, 18]
}
```

Combine with `firstSourceIds` to find leads that originated from one source but have since been re-assigned to another — e.g. `firstSourceIds: [5]` + `sourceIds: [12]` finds leads that first came in via source 5 and are now sitting under source 12.

---

### Filter by status ID (parent includes all children)

`UserLeadStatus` is a tree — a parent status has children, which may have grandchildren, and so on. Passing a parent `statusId` automatically expands to include all its descendants.

Finds leads whose **interactions** were logged with status `5` (or any of its child statuses), in September 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "statusId": 5
        }
      ]
    }
  ]
}
```

Finds leads whose **current lead status** is `2` (or any of its child statuses), created in August 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "LEAD_CREATED",
          "dateFrom": "2025-08-01",
          "dateTo": "2025-08-31",
          "statusId": 2
        }
      ]
    }
  ]
}
```

---

### Filter by UTM parameters

Finds leads whose **interaction activity** came from Google CPC traffic in September 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "utms": {
            "utm_source": "google",
            "utm_medium": "cpc"
          }
        }
      ]
    }
  ]
}
```

Finds leads created from a specific campaign (UTMs stored on the lead itself).

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "LEAD_CREATED",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "utms": {
            "utm_campaign": "summer-sale"
          }
        }
      ]
    }
  ]
}
```

---

### Combined — interaction status ID + UTM + payment status in one request

Finds leads that **either**:
- Had an interaction with status ID `5` from Facebook ads in Sep 2025, **or**
- Completed a successful payment after submitting the `"trial-form"` form.

```json
POST /api/command/all-leads-filter

{
  "operator": "OR",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-30",
          "statusId": 5,
          "utms": { "utm_source": "facebook" }
        }
      ]
    },
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "CONTACT_FORM",
          "slug": "trial-form"
        },
        {
          "type": "PAYMENT_DONE",
          "status": "success"
        }
      ]
    }
  ]
}
```

---

### Lead created on a date OR had an interaction on another date

Finds leads that either arrived on 1 Sep 2025 **or** had an interaction on 3 Sep 2025.

```json
POST /api/command/all-leads-filter

{
  "operator": "OR",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "LEAD_CREATED",
          "dateFrom": "2025-09-01",
          "dateTo": "2025-09-01"
        }
      ]
    },
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "INTERACTION",
          "dateFrom": "2025-09-03",
          "dateTo": "2025-09-03"
        }
      ]
    }
  ]
}
```

---

### Multiple event combinations with top-level OR

Finds leads that match **either** of these scenarios:
- Scenario A: Lead came on 15 Aug AND payment on 17 Aug
- Scenario B: Lead came on 1 Sep AND had a contact-form submission on 3 Sep

```json
POST /api/command/all-leads-filter

{
  "operator": "OR",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        { "type": "LEAD_CREATED", "dateFrom": "2025-08-15", "dateTo": "2025-08-15" },
        { "type": "PAYMENT_DONE", "dateFrom": "2025-08-17", "dateTo": "2025-08-17" }
      ]
    },
    {
      "operator": "AND",
      "conditions": [
        { "type": "LEAD_CREATED", "dateFrom": "2025-09-01", "dateTo": "2025-09-01" },
        { "type": "CONTACT_FORM", "dateFrom": "2025-09-03", "dateTo": "2025-09-03" }
      ]
    }
  ]
}
```

---

### Date range query — leads with payment within a week

Omit `dateFrom` / `dateTo` on a condition to make it open-ended, or supply a range to span multiple days.

```json
POST /api/command/all-leads-filter

{
  "operator": "AND",
  "groups": [
    {
      "operator": "AND",
      "conditions": [
        {
          "type": "PAYMENT_DONE",
          "dateFrom": "2025-08-01",
          "dateTo": "2025-08-07"
        }
      ]
    }
  ]
}
```

---

### Pagination

Pass `page` to fetch subsequent pages. Page size is fixed at 50.

```json
{
  "operator": "AND",
  "groups": [ { "operator": "AND", "conditions": [ { "type": "LEAD_CREATED", "dateFrom": "2025-08-15", "dateTo": "2025-08-15" } ] } ],
  "page": 1
}
```

---

## Bulk-assign leads to a source

Assign a set of leads to a lead source in one call — either explicit lead IDs (per-row checkbox selection) or every lead currently matching an `all-leads-filter` query ("select all").

```
POST /api/command/bulk-assign-lead-source
Content-Type: application/json
```

**Required permission:** `canViewEmployeeToLeadSources` (same permission gate as the existing "add leads" / "add lead source" endpoints).

### Request body

| Field | Type | Required | Description |
|-------|------|----------|--------------|
| `sourceId` | integer | **Yes** | The `LeadSource` ID to assign the matched leads to. |
| `leadIds` | integer[] | One of `leadIds` / `filter` | Explicit lead IDs (checkbox multi-select). **Takes precedence over `filter` when both are supplied.** |
| `filter` | `LeadQueryFilterDto` | One of `leadIds` / `filter` | Same shape as the `all-leads-filter` body above ("select all" — re-resolved server-side against the *current* data, not a snapshot of what the UI last rendered). |

Exactly one of `leadIds` / `filter` should be sent. Omitting both returns `400 Bad Request`.

### What it updates

For every matched lead:

| Field | New value | Why |
|-------|-----------|-----|
| `sourceId` | the requested `sourceId` | Re-point the lead at the new source. |
| `action` | `"Call"` | Makes the lead callable again under the new source (mirrors how re-adding an existing lead via `/add-leads` behaves). |
| `employeeId` | `null` | Unassigns from whoever currently owns the lead, so it re-enters the unassigned pool and becomes eligible for distribution under the new source. |

`firstSourceId` (original attribution) and `priority` are left untouched.

### Response

```json
{ "message": "Leads assigned to source successfully", "count": 37 }
```

`count` is the number of `UserLead` rows actually updated.

### Examples

**Per-row selection:**

```json
POST /api/command/bulk-assign-lead-source

{
  "sourceId": 12,
  "leadIds": [101, 102, 108, 115]
}
```

**"Select all" matching the current advanced filter** (e.g. all leads with no payment in May 2026):

```json
POST /api/command/bulk-assign-lead-source

{
  "sourceId": 12,
  "filter": {
    "operator": "AND",
    "groups": [
      {
        "operator": "AND",
        "conditions": [
          { "type": "PAYMENT_DONE", "dateFrom": "2026-05-01", "dateTo": "2026-05-31", "negate": true }
        ]
      }
    ]
  }
}
```

### Frontend: individual select / select-all

State to add alongside `filterGroups`/`filterOperator` from the advanced filter panel:

| Variable | Type / Default | Description |
|----------|----------------|--------------|
| `selectedLeadIds` | `Set<number>` / `new Set()` | Checked rows on the current page |
| `selectAllMatching` | `boolean` / `false` | "Select all N leads matching this filter" banner state, distinct from selecting only the visible page |

```js
function toggleLeadSelected(leadId) {
  if (selectedLeadIds.has(leadId)) selectedLeadIds.delete(leadId);
  else selectedLeadIds.add(leadId);
  selectAllMatching = false; // explicit row toggle overrides "select all"
}

function selectAllOnPage(leads) {
  leads.forEach(l => selectedLeadIds.add(l.id));
}

function selectAllMatchingFilter() {
  selectAllMatching = true;   // don't materialise every ID client-side — send `filter` instead
  selectedLeadIds.clear();
}

async function assignSelectedToSource(sourceId) {
  const body = selectAllMatching
    ? { sourceId, filter: buildFilterBody() }          // "select all" — reuse the same filter body
    : { sourceId, leadIds: Array.from(selectedLeadIds) };

  const res = await fetch(`${BASE_URL}/bulk-assign-lead-source`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${getToken()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(res.status);
  const { count } = await res.json();
  showToast(`${count} leads assigned`, 'success');
  selectedLeadIds.clear();
  selectAllMatching = false;
  reloadLeads();
}
```

`buildFilterBody()` is the same helper already defined above for `all-leads-filter` — the "select all" case just forwards the exact filter currently applied on screen, so the backend re-resolves the matching set fresh (it is not the list of IDs the table happened to have rendered).

---

## Common error responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Validation failed — missing required fields, invalid `type`/`operator` enum value, or (bulk-assign) neither `leadIds` nor `filter` supplied / unknown `sourceId` |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Employee does not have `canViewAllLeads` (`all-leads-filter`) or `canViewEmployeeToLeadSources` (`bulk-assign-lead-source`) permission |

---

## How it maps to the database

The filter builds a nested Prisma `where` clause on `UserLead`:

| `type` | Prisma clause |
|--------|---------------|
| `LEAD_CREATED` | `{ createdAt: { gte, lte }, platformId?, statusId: { in: [...] }?, AND: [UTMs path filters] }` |
| `PAYMENT_DONE` | `{ statusId: { in: [...] }?, UserActivity: { some: { paymentId: { not: null }, Payment: { status }, createdAt: { gte, lte }, AND: [utmFields path filters] } } }` |
| `INTERACTION` | `{ UserActivity: { some: { interactionId: { not: null }, Interaction: { leadStatusId: { in: [...] }? }, createdAt: { gte, lte }, AND: [utmFields path filters] } } }` |
| `CONTACT_FORM` | `{ statusId: { in: [...] }?, UserActivity: { some: { contactFormId: { not: null }, ContactForm: { slug? }, createdAt: { gte, lte }, AND: [utmFields path filters] } } }` |
| `CART_CREATED` | `{ statusId: { in: [...] }?, UserActivity: { some: { cartId: { not: null }, createdAt: { gte, lte }, AND: [utmFields path filters] } } }` |
| `NEW_SIGNUP` | `{ userId: { not: null }, createdAt: { gte, lte }, platformId?, statusId: { in: [...] }?, AND: [UTMs path filters] }` |

**Status ID resolution** (`statusId: { in: [...] }`): when a `statusId` is supplied the server does a BFS walk of the `UserLeadStatus` tree starting at that ID, collecting all descendant IDs. The resulting array is used in the `in` clause so the filter matches any lead (or interaction) with that status *or any of its children*.

UTM clauses use Prisma's JSON path filter: `{ utmFields: { path: [key], equals: value } }`. All supplied UTM pairs are AND-combined.

Conditions within a group are wrapped in `{ AND: [...] }`, `{ OR: [...] }`, or `{ NOT: { OR: [...] } }` depending on the group's `operator`. Groups are then combined the same way at the top level, using the same three-way rule on `LeadQueryFilterDto.operator`. The top-level `where` clause is always scoped to the caller's own `platformId` (resolved server-side from the employee's token/origin) — a client-supplied `platformId` in the request body is ignored for that scoping; it only ever narrows `LEAD_CREATED`/`NEW_SIGNUP` conditions further. `firstSourceIds` ANDs in `{ firstSourceId: { in: [...] } }` and `sourceIds` ANDs in `{ sourceId: { in: [...] } }` at the same top level — both are plain scalar filters on `UserLead`, not per-condition.

**`negate`** (per-condition): the condition's normal clause is computed first, then wrapped as `{ NOT: <clause> }` before being placed into its group. For relation filters (`UserActivity: { some: {...} }`) this is Prisma's standard way of expressing "no such related record exists" — it becomes a NOT EXISTS at the SQL level, equivalent to `UserActivity: { none: {...} } }` but composes correctly inside AND/OR groups.

**`operator: "NOT"`** (group-level or top-level): `{ NOT: { OR: [clause1, clause2, ...] } }` — "none of these match" is the negation of "at least one matches" (De Morgan's law: `NOT(A OR B)` = `NOT A AND NOT B`, so this is equivalent to negating every clause individually and ANDing them, just expressed with a single wrapper). This composes with per-condition `negate` freely, since each `clauseN` may already itself be a `{ NOT: ... }` from its own `negate: true`.

---

## Frontend Integration

The All Leads screen already exists and uses `GET /all-leads` with the standard filters (date range, source, employee, status, course, slug, isEnrolled). This section explains how to wire an **Advanced Filter** panel into that screen backed by `POST /all-leads-filter`.

### When to use which endpoint

| Situation | Endpoint |
|-----------|----------|
| Standard date/source/employee/status filters | `GET /all-leads` — keep as-is |
| Cross-event queries ("lead at date X AND payment at date Y") | `POST /all-leads-filter` — advanced filter panel |

Do not merge the two endpoints. Activate the advanced filter when the user opens the filter builder panel; fall back to `GET /all-leads` when the panel is closed / cleared.

---

### State variables

Add these to your existing All Leads screen state:

| Variable | Type / Default | Description |
|----------|---------------|-------------|
| `advancedFilterOpen` | `boolean` / `false` | Whether the advanced filter panel is visible |
| `filterOperator` | `"AND"` \| `"OR"` \| `"NOT"` / `"AND"` | Top-level operator connecting groups |
| `filterGroups` | `FilterGroup[]` / `[]` | Current list of filter groups |
| `filterPage` | `number` / `0` | 0-indexed page for the advanced filter result |
| `filterTotal` | `number` / `0` | Total count returned by last advanced filter call |
| `filterFirstSourceIds` | `number[]` / `[]` | Top-level first-touch source filter |
| `filterSourceIds` | `number[]` / `[]` | Top-level current-source filter |

```js
// Minimal FilterGroup shape mirroring the API
// {
//   operator: "AND"|"OR"|"NOT",
//   conditions: [{
//     type, dateFrom?, dateTo?,
//     status?, slug?, platformId?, utms?,
//     employeeIds?, negate?
//   }]
// }

const DEFAULT_CONDITION = () => ({ type: 'LEAD_CREATED', dateFrom: '', dateTo: '', negate: false });
const DEFAULT_GROUP     = () => ({ operator: 'AND', conditions: [DEFAULT_CONDITION()] });

let advancedFilterOpen    = false;
let filterOperator        = 'AND';
let filterGroups          = [];
let filterPage            = 0;
let filterTotal           = 0;
let filterFirstSourceIds  = [];
let filterSourceIds       = [];
```

---

### Building the request body

**This is the part that's easy to miss:** every field on a condition or on the top-level body must be explicitly forwarded here. If a field exists in the UI state but isn't listed in this function, it is silently dropped and never reaches the backend — the filter will look "applied" in the UI but do nothing server-side. When adding a new filter field to the panel (or wiring up one already documented above, like `sourceIds`, `employeeIds`, `negate`), update this function in the same change.

```js
function buildFilterBody() {
  return {
    operator: filterOperator,
    groups: filterGroups.map(g => ({
      operator: g.operator,
      conditions: g.conditions
        .filter(c => c.type)           // drop empty rows
        .map(c => ({
          type: c.type,
          ...(c.dateFrom     && { dateFrom:     c.dateFrom }),
          ...(c.dateTo       && { dateTo:       c.dateTo }),
          ...(c.status       && { status:       c.status }),
          ...(c.slug         && { slug:         c.slug }),
          ...(c.platformId   && { platformId:   c.platformId }),
          ...(c.statusId     && { statusId:     c.statusId }),
          ...(c.utms && Object.keys(c.utms).length && { utms: c.utms }),
          ...(c.employeeIds && c.employeeIds.length && { employeeIds: c.employeeIds }), // INTERACTION only
          ...(c.negate       && { negate: true }),
        })),
    })).filter(g => g.conditions.length > 0),  // drop empty groups
    page: filterPage,
    ...(filterFirstSourceIds.length && { firstSourceIds: filterFirstSourceIds }),
    ...(filterSourceIds.length      && { sourceIds: filterSourceIds }),
  };
}
```

---

### Fetching leads

```js
const BASE_URL = '{{baseUrl}}/api/command';

function getToken() {
  return localStorage.getItem('employee_jwt');
}

async function fetchFilteredLeads() {
  const body = buildFilterBody();
  if (!body.groups.length) return;   // nothing to query

  showLoader(true);
  try {
    const res = await fetch(`${BASE_URL}/all-leads-filter`, {
      method:  'POST',
      headers: {
        'Authorization': `Bearer ${getToken()}`,
        'Content-Type':  'application/json',
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(res.status);

    const { leads, total, page } = await res.json();
    filterTotal = total;
    filterPage  = page;
    renderLeads(leads);     // reuse your existing lead-row renderer
    renderPagination();
  } catch (e) {
    showToast('Failed to load leads', 'error');
    console.error(e);
  } finally {
    showLoader(false);
  }
}
```

---

### Pagination

The API returns 50 leads per page. If your table shows fewer rows per page, paginate client-side within the 50, and re-fetch when the user moves past the last row of the current batch (same pattern as the calling dashboard — see `lead-admin-api.md` §8, Option A).

```js
function goToFilterPage(n) {
  filterPage = n;
  fetchFilteredLeads();
}
```

---

### Suggested filter builder UI

```
┌─ Advanced Filter ──────────────────────────────────────────────────────────────────┐
│  Top-level:  [ AND ▾ ]  (AND / OR / NOT)                                            │
│                                                                                     │
│  ┌─ Group 1 ─────────────────────────────────── inner: [ AND ▾ ] (AND/OR/NOT) ──┐   │
│  │  [INTERACTION ▾]  from [2025-09-01]  to [2025-09-30]  [ ] Negate (NOT)       │   │
│  │                   status [connected ▾]  employees [+ Add] utms [+ Add UTM]  │   │
│  │  [CONTACT_FORM ▾] from [          ]  to [          ]  slug [demo-request]   │   │
│  │  + Add condition                                                             │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  + Add group                                          [ Clear ]  [ Apply ]         │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

**Per-type extra fields shown in the UI:**

| `type` | Extra inputs |
|--------|-------------|
| `INTERACTION` | Status ID picker (hierarchical — selecting a parent auto-includes children, matched on `UserLeadInteraction.leadStatusId`) · Employee multi-select (`employeeIds`) · UTM key-value pairs |
| `PAYMENT_DONE` | Status dropdown (success, pending, cancelled, awaited) · Status ID picker (matched on `UserLead.statusId`) · UTM key-value pairs |
| `CONTACT_FORM` | Slug text input · Status ID picker (matched on `UserLead.statusId`) · UTM key-value pairs |
| `CART_CREATED` | Status ID picker (matched on `UserLead.statusId`) · UTM key-value pairs |
| `LEAD_CREATED` | Platform ID input · Status ID picker (matched on `UserLead.statusId`) · UTM key-value pairs (matched on `UserLead.UTMs`) |
| `NEW_SIGNUP` | Platform ID input · Status ID picker (matched on `UserLead.statusId`) · UTM key-value pairs (matched on `UserLead.UTMs`) |

Every condition, regardless of `type`, also gets a **"Negate (NOT)"** checkbox — bound to `condition.negate` — for "this specific thing did NOT happen" queries (see [Negation (NOT) filters](#negation-not-filters)).

**Controls and their actions:**

| Control | Action |
|---------|--------|
| Top-level `[AND ▾]` toggle | Cycle `filterOperator` through `"AND"` / `"OR"` / `"NOT"` |
| Inner `[AND ▾]` toggle per group | Cycle `group.operator` through `"AND"` / `"OR"` / `"NOT"` |
| Type dropdown `[LEAD_CREATED ▾]` | Set `condition.type`; show/hide extra fields accordingly |
| `from` / `to` date inputs | Set `condition.dateFrom` / `condition.dateTo` |
| Status dropdown | Set `condition.status` (shown for `PAYMENT_DONE` only) |
| Slug input | Set `condition.slug` (shown for `CONTACT_FORM`) |
| Platform ID input | Set `condition.platformId` (shown for `LEAD_CREATED`, `NEW_SIGNUP`) |
| Employee multi-select | Set `condition.employeeIds` (shown for `INTERACTION` only) |
| `Negate (NOT)` checkbox | Set `condition.negate` (shown for every type) |
| `+ Add UTM` / UTM rows | Push `{ key, value }` rows; serialise to `condition.utms` before sending |
| `+ Add condition` | Push `DEFAULT_CONDITION()` into `group.conditions` |
| `×` on a condition row | Splice that condition out |
| `+ Add group` | Push `DEFAULT_GROUP()` into `filterGroups` |
| `×` on a group | Splice that group out |
| `[ Apply ]` | Reset `filterPage = 0`, call `fetchFilteredLeads()` |
| `[ Clear ]` | Reset `filterGroups = []`, `filterOperator = "AND"`, `filterPage = 0`, switch back to `GET /all-leads` |

---

### Group / condition helpers

```js
function addGroup() {
  filterGroups.push(DEFAULT_GROUP());
  renderFilterBuilder();
}

function removeGroup(groupIndex) {
  filterGroups.splice(groupIndex, 1);
  renderFilterBuilder();
}

function addCondition(groupIndex) {
  filterGroups[groupIndex].conditions.push(DEFAULT_CONDITION());
  renderFilterBuilder();
}

function removeCondition(groupIndex, condIndex) {
  filterGroups[groupIndex].conditions.splice(condIndex, 1);
  if (!filterGroups[groupIndex].conditions.length) removeGroup(groupIndex);
  renderFilterBuilder();
}

function setGroupOperator(groupIndex, op) {
  filterGroups[groupIndex].operator = op;
}

function setConditionField(groupIndex, condIndex, field, value) {
  filterGroups[groupIndex].conditions[condIndex][field] = value;
}

function applyFilter() {
  filterPage = 0;
  advancedFilterOpen = true;
  fetchFilteredLeads();
}

function clearFilter() {
  filterGroups      = [];
  filterOperator    = 'AND';
  filterPage        = 0;
  advancedFilterOpen = false;
  // resume normal GET /all-leads call
  fetchLeads();
}
```

---

### Switching between normal and advanced mode

```js
// Call this wherever you currently trigger a leads reload
function reloadLeads() {
  if (advancedFilterOpen && filterGroups.length) {
    fetchFilteredLeads();
  } else {
    fetchLeads();   // existing GET /all-leads call
  }
}
```

This means the standard filters (employee, source, status, date range) keep working exactly as before when the advanced panel is closed. Opening the panel and pressing **Apply** switches the data source; pressing **Clear** switches back.

---

### Rendering the response

The `leads` array in the response has the same shape as each element returned by `GET /all-leads`, so your existing lead-row renderer works without changes. Key included relations:

| Relation | Path |
|----------|------|
| Assigned employee | `lead.Employee` |
| Lead source | `lead.LeadSource`, `lead.FirstSource` |
| Current status | `lead.LeadStatus` |
| Activities | `lead.UserActivity[]` — each entry has `.Payment`, `.Cart`, `.ContactForm`, `.Interaction.Employee` |
