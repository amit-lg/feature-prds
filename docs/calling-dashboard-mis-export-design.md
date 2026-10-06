# Calling Dashboard — MIS Lead Report Download

Status: Draft
Owner: TBD
Source spec: `docs/MIS__Student Success Team - Input-Leads.csv` (1005-row weekly/monthly lead-funnel pivot, Aug'25–Jul'26)
Related code: `src/lead/lead.service.ts` (`getLeadStatsTempNew`, `getLeadStatsTempNewV2`, `getEmployeeLeadStats`), `src/command/command.controller.ts`

## 1. What the target file actually is

The CSV is a wide pivot table, not a plain export. Structure:

- **Header (row 2)**: `Concate, Type, Category, Sub-Category, Data Type, Metrics, Status, Apr'26-Target`, then repeating week/month columns from `Aug'25 W1` through `Jul'26`, each month rendered as 4 weekly columns (`W1`–`W4`) followed by a monthly total column.
- **Data rows**: one row per `(Type, Category/Sub-Category, Data Type, Metrics)` combination. `Type` is one of:
  - `All` — every lead touch in the period (a lead can count more than once if touched across weeks).
  - `Unique` — distinct leads, counted once, in the period they were created.
  - `Followup` (`Followup-Received` / `Followup-Not Received`) — leads that required a *repeat* contact attempt, split by whether that attempt connected.
  - `Source` — same metric set as `All`/`Unique`, but broken out per lead source (in the sheet, some sources are further nested into a parent, e.g. `Website → Cart / Landing Page / Sign Up / Incoming`).
- **Metrics** per row (for `All`/`Unique`/`Source`): Total Leads, Received (+%), Not Received (+%), Not Connected (+%), Interested (+%), Deferred (+%), Career Enquiry, Non Workable (+%), Call Back (+%), Not Interested (+%), Invalid, No Contact (+%), Converted (+%), International (+%), Enquired to New Course (+%), Already Enrolled (+%), New course enquiry (+%), New Enquiry. `Followup` rows use a smaller subset (Total Leads, Received(+%), Interested(+%), Invalid, No Enquiry(+%), Not Received(+%), Not Connected(+%), Pending).
- **Status / Apr'26-Target columns**: manually annotated "Achieved" flags and hand-entered targets on a handful of rows — not derived from lead data anywhere in the schema.

Per your decisions, v1 scope is: **flat per-source rows (no Category/Sub-Category nesting), no Status/Target columns, full history recomputed live on every download** (Aug'25 → current week, from event data — not a frozen snapshot).

## 2. Why this isn't a simple export — the two hard problems

### 2.1 Historical status counts must come from `UserLeadInteraction`, not `UserLead.status`

`UserLead.status` / `statusId` is **current state**, overwritten on every status change — there's no way to ask "what was this lead's status during the week of Sep 15?" from `UserLead` alone. But `UserLeadInteraction` (`prisma/schema.prisma:2567`) is an append-only log: each row has its own `createdAt`, `leadStatusId`, `isConnected`, `isDone`. That's the actual event stream, and it's what the weekly buckets must be computed from — e.g. "Interested, Sep'25 W3" = distinct leads with a `UserLeadInteraction` in that week whose `leadStatusId` resolved to a status named "Interested".

This means the report is fundamentally an aggregation over `UserLeadInteraction` joined to `UserLeadStatus`, filtered by a computed week range — not a `GROUP BY` over `UserLead` directly. `Total Leads` and `Unique` counts are the exception: those come from `UserLead.createdAt` falling in the period.

### 2.2 Metric labels don't map 1:1 to `UserLeadStatus.name` yet — needs confirmation, not guessing

Some metrics are clearly a direct status match (`Interested`, `Converted`, `Deferred`, `Not Interested`, `Invalid`, `Career Enquiry`, `Non Workable`, `Call Back`, `Already Enrolled`, `Enquired to New Course`, `New course enquiry`, `International`). Others are ambiguous without seeing the live `UserLeadStatus` table for this platform:

- `Received` vs `Not Received` — is "Received" = "≥1 connected interaction in period" (`isConnected = true`), or a specific status?
- `Not Connected` vs `No Contact` — the sheet has both as distinct, non-equal series (e.g. row 8 "Not Connected" and row 22 "No Contact" diverge in most weeks). These look like different things ("attempted, didn't pick up" vs "never attempted"), but that's an inference, not a confirmed definition.
- `New Enquiry` and `Pending` (Followup only) — likely raw `UserLeadStatus.name` values, but need confirming against what actually exists in the DB for this platform (statuses are per-install free text, not an enum).

**This is the one part of the design that can't be resolved by reading code — it needs a short mapping session against the live `UserLeadStatus` table** (I can pull the actual status list and draft the mapping for review, but the "is X included in No Contact" calls are a business decision). Everything else in this doc can proceed in parallel.

### 2.3 Week boundary definition

`W1`–`W4` per month don't divide evenly (28–31 day months). Proposed convention pending confirmation: **W1 = days 1–7, W2 = 8–14, W3 = 15–21, W4 = 22–end-of-month** (calendar-day buckets, not ISO weeks — the sheet's monthly totals are simple sums of the 4 weekly buckets, which is consistent with this scheme and inconsistent with ISO weeks that can straddle months).

## 3. Data model

No schema changes required for v1 (flat sources, no targets). One addition worth considering:

- `UserLeadInteraction` has no index on `(leadStatusId, createdAt)` today — worth adding, since every metric cell in this report is effectively `COUNT(DISTINCT leadId) WHERE leadStatusId = X AND createdAt BETWEEN week_start AND week_end`, repeated across ~50 weeks × ~15 metrics × (all sources + All/Unique/Followup). Without it, this endpoint will do a lot of sequential scanning.

## 4. Computation approach

New module: `src/mis-report/` (a new `MisReportService`/`MisReportController`, not bolted onto `lead.service.ts`, which is already large and this is a distinct reporting concern).

1. Resolve the report window: fixed start `2025-08-01` (matching the existing sheet's inception), end = current week, both configurable via query params for future reports.
2. Build the week/month column list for that window (reuse across all rows).
3. Load `LeadSource` list for the platform (flat — one row per source, per your v1 decision).
4. For each `(Type, Source|null)` combination, run one batched aggregation query per metric group across the full window rather than one query per week-cell — e.g. `SELECT date_trunc('week-bucket', ui.createdAt), ui.leadStatusId, COUNT(DISTINCT ui.leadId) FROM UserLeadInteraction ui JOIN UserLead ul ON ... WHERE ul.platformId = ? AND ui.createdAt BETWEEN ? AND ? GROUP BY 1, 2`, then pivot the results into weekly/monthly cells in application code. This keeps query count roughly proportional to `(Type × Source)` rather than `(Type × Source × Week × Metric)`.
5. `All` vs `Unique` reuse the counting distinction already implemented in `getLeadStatsTempNewV2` (`lead.service.ts`) — that split (touched-in-period vs created-in-period) is exactly `All` vs `Unique` here, so the existing query logic is a starting point, not a rewrite.
6. `Followup-Received` / `Followup-Not Received` filter to leads *not* newly created in the period (i.e. a repeat contact) and split by `isConnected` on the qualifying interaction — mirrors the existing `action: 'followup'/'followup1'` handling already in `lead.service.ts`.
7. Serialize to CSV in the exact column order/header from section 1, one row per `(Type, Source, Metric)`, formatting percentages and thousands separators to match the source file (`"4,349"`, `57%`).

## 5. API

```
GET /command/mis-report/leads/download
  ?from=2025-08-01&to=<current-week-end>   (optional, defaults to full history)
  &format=csv                               (only format for v1)
  → Content-Type: text/csv
    Content-Disposition: attachment; filename="Leads-MIS-<generatedAt>.csv"
```

Modeled on the existing download pattern in `src/user/user.controller.ts:434-450` (`createAnalysisPdf` — buffer + `Content-Disposition` headers), swapped for a CSV buffer/stream. Guarded by `EmployeeAuthGuard` + a new permission `canDownloadLeadMis` (add to `permissionsStrings.txt`).

## 6. Performance & UX for a live, full-history recompute

Given the "recompute live, every time" decision: this is a genuinely heavy query (year of data × every source × every metric). Mitigations to build in from the start, not as a later optimization:

- Run it as a background/async job rather than a synchronous request-response: `POST` kicks off generation, returns a job id; employee polls or gets a socket event (`/command` namespace, existing `NotificationService.sendNotification` pattern) with a download URL when ready. A multi-second-to-tens-of-seconds synchronous HTTP call behind a dashboard button is a bad UX and risks gateway timeouts.
- Only the **current, still-open week** is genuinely "live" — every prior week is closed and its numbers can't change once interactions stop landing in that date range. So while every download recomputes the full range end-to-end today, this is a strong candidate for a cache-closed-weeks optimization later (compute once, invalidate never, except the trailing partial week) without changing the "always full history" behavior the button exposes.

## 7. Open items before implementation starts

1. **Metric → status mapping** (section 2.2) — needs the live `UserLeadStatus` list for this platform reviewed against the 20-ish metric labels. I can pull the current status table and propose a mapping for sign-off as the first implementation step.
2. **Week boundary convention** (section 2.3) — confirm days-1-7/8-14/15-21/22-end, or the actual rule used when the sheet was built.
3. Confirm `Received` = "connected interaction" (`isConnected = true`) vs a dedicated status, and how `Not Connected` differs from `No Contact`.
4. Confirm the report's fixed start date (Aug'25) should stay hardcoded as the default, vs. becoming "current fiscal year to date."

## 8. Rollout

1. Confirm section 7 with the data/business owner (short exercise, blocks nothing else).
2. Add `(leadStatusId, createdAt)` index on `UserLeadInteraction`.
3. Build `MisReportService` with the batched-aggregation approach in section 4, backed by the confirmed metric map.
4. Add the async job + `/command/mis-report/leads/download` endpoint and permission.
5. Command console: "Download MIS" button on the calling dashboard, wired to kick off the job and download the CSV when ready.
6. Validate output against a recent week of the existing hand-maintained sheet before treating this as the source of truth.
