# Calling Dashboard — Technical Requirements Document

**Project:** UXL CRM — Leveraged Growth Pvt Ltd  
**File:** `calling-dashboard.html` (~126 KB, single file)  
**Prepared for:** Frontend / Backend Developer  
**Date:** June 2026  
**Status:** 🟡 UI Complete · API Integration Pending

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [API Endpoints](#3-api-endpoints)
4. [Field Mapping](#4-field-mapping-api--ui)
5. [State Variables](#5-state-variables)
6. [Function Reference](#6-function-reference)
7. [Filter → API Param Mapping](#7-filter--api-param-mapping)
8. [Integration Steps](#8-integration-steps)
9. [mapInteraction() Implementation](#9-mapinteraction-implementation)
10. [Recording Player Wiring](#10-recording-player-wiring)
11. [Follow-Up Level — Backend Requirement](#11-follow-up-level--backend-requirement)
12. [Status Tree](#12-status-tree)
13. [Open Items — Confirm with Backend](#13-open-items--confirm-with-backend)

---

## 1. Overview

The Calling Dashboard is a **vanilla JS single-page app** with no build step or bundler. Chart.js is loaded from CDN. Everything — HTML, CSS, JS — lives in one file.

**Current state:** Fully working UI driven by `genCalls(120)` which generates 120 mock call records. Your job is to replace `genCalls()` with real API calls and wire up all filters to query params.

**Design system:** Navy `#2D3E51` · Crimson `#E64D3D` · Background `#F0F2F5` · Font: DM Sans

### What the dashboard shows

| Section | Description |
|---------|-------------|
| **7 Volume cards** | Total Leads, Total Calls, Unique Calls, No Contact, FU 1, FU 2, FU 3 |
| **4 Direction cards** | Incoming, Outgoing, Total Dial Time, Total Talk Time |
| **4 Performance cards** | Connection Rate, Avg Talk Duration, Avg Dial Time, Avg Calls/Lead |
| **2 Highlight cards** | Best Calling Hour, Longest Call |
| **3 Charts** | Calls by Hour (bar), Daily Trend (dual line), Status Breakdown (donut) |
| **Leaderboard** | Employees ranked by calls, click to filter |
| **Call Log table** | Searchable, sortable, paginated (12/page), inline recording player |
| **Employee Table** | Per-employee stats side-by-side, sortable |

### View modes (single 3-option toggle)

```
[ All ]  [ My Calls ]  [ Employee Table ]
```

| Mode | `curView` | `curLayout` | Endpoint used |
|------|-----------|-------------|---------------|
| All | `"admin"` | `"dash"` | `/lead-interactions` |
| My Calls | `"mine"` | `"dash"` | `/my-lead-interactions` |
| Employee Table | `"admin"` | `"table"` | `/lead-interactions` |

---

## 2. Architecture

### File structure

```
calling-dashboard.html
├── <style>              CSS — design tokens, components, dark mode (140+ rules)
├── Sidebar HTML         Shared sidebar (same as leads.html)
├── Main content HTML
│   ├── Top navbar
│   ├── Page header      Title + 3-option toggle + Help + Refresh buttons
│   ├── Filter row        Employee select, Date, Status, Sub-status, FU level, Direction, Connected toggle
│   ├── #dashView         Stat cards (3 rows), Highlight cards, Charts, Leaderboard, Call Log
│   ├── #empTableSection  Employee stats table (hidden by default)
│   └── #helpModal        Metric definitions popup
└── <script>
    ├── STATUS_TREE[]     Status hierarchy (hardcoded from UserLeadStatus.csv)
    ├── STATUS_BY_ID{}    Flat lookup built by flattenStatuses()
    ├── Mock data         genCalls(n) ← REPLACE THIS
    ├── State vars        curView, curLayout, activeEmp, filters, pagination, sort
    ├── Render fns        renderStats(), initCharts(), renderLeaderboard(), renderLog()
    ├── Filter fns        getFiltered(), setStatusFilter(), setFUFilter(), ...
    ├── UI fns            setMode(), toggleDark(), playRecording(), openHelp()
    └── Init              buildEmpFilter(), buildStatusFilter(), setMode('all')
```

### Data flow

```
User changes filter
  └─ state variable updated
  └─ renderAll() called
       ├─ getFiltered()        applies ALL filters to allCalls[]
       ├─ renderStats()        computes + animates all card values
       ├─ initCharts()         destroys + rebuilds Chart.js instances
       ├─ renderLeaderboard()  groups by employee, renders rows
       └─ renderLog()          sorts + paginates + renders table rows

On mode switch (All / My Calls / Employee Table):
  └─ setMode(v) called
       ├─ updates curView, curLayout
       ├─ shows/hides dashView vs empTableSection
       └─ calls renderAll() or renderEmpTable()
```

**Rule:** `getFiltered()` is pure — it reads `allCalls[]` and all filter state, returns a filtered array. It never makes API calls. Put API calls in `fetchCalls()` (to be implemented).

---

## 3. API Endpoints

**Base URL:** `{{baseUrl}}/api/command`  
**Auth:** `Authorization: Bearer <employee_jwt>` on every request  
**Admin endpoints** additionally require `canViewAllLeads` permission.

| Method | Endpoint | Scope | Use for |
|--------|----------|-------|---------|
| `GET` | `/lead-interactions` | Admin | Primary call list — all employees |
| `GET` | `/lead-interactions/count` | Admin | Total count for pagination |
| `GET` | `/lead-interactions/status-count` | Admin | Donut chart status breakdown |
| `GET` | `/my-lead-interactions` | Employee | Call list — own calls only |
| `GET` | `/my-lead-interactions/count` | Employee | Own call count |
| `GET` | `/my-lead-interactions/status-count` | Employee | Own status breakdown |

### Query parameters

| Param | Type | Description |
|-------|------|-------------|
| `employeeIds` | `number[]` | Admin only. JSON array, comma-separated, or single value. |
| `leadStatusIds` | `number[]` | Filter by `UserLeadStatus` IDs. Leave empty = all. |
| `startDate` | ISO string | Start of range, normalised to start-of-day IST. |
| `endDate` | ISO string | End of range, normalised to end-of-day IST. |
| `page` | number | Zero-based. Page size fixed at **50**. |
| `direction` | `"in"` \| `"out"` | Optional. `in` = incoming, `out` = outgoing (everything not flagged incoming). Omit for both. |
| `interaction` | `"call"` \| `"followup"` \| `"followup1"` \| `"followup2"` \| `"followup3"` \| `"retention"` | Optional. Filters by the `interaction` column on `UserLeadInteraction`. Matching is case-insensitive. `"call"` also matches records where the field is `null` or empty string. Omit for all types. |
| `search` | string | Optional. Free-text search across `fname`, `lname`, `email`, and `phone` on both the interaction's direct `User` and the linked `Lead`. A string containing a space is split at the first space and matched as `fname + lname` against both. |

### Response shape — list endpoints

```json
{
  "id": 12345,
  "employeeId": 7,
  "callDialTime": "2026-06-05T09:30:00.000Z",
  "callUpTime":   "2026-06-05T09:30:08.000Z",
  "callEndTime":  "2026-06-05T09:32:30.000Z",
  "isDone": true,
  "leadStatusId": 20,
  "ringDurationSeconds": 8,
  "talkDurationSeconds": 142,
  "totalDurationSeconds": 150,
  "direction": "out",
  "connected": true,
  "followUpLevel": 1,
  "recordingUrl": "https://.../phone_recording_12345_....mp3",
  "Employee": {
    "id": 7, "fname": "Asha", "lname": "Rao",
    "email": "asha@example.com", "profile": "..."
  },
  "EmployeeStatus": { "id": 20, "name": "Hot" },
  "User": {
    "id": 101, "fname": "Priya", "lname": "Sharma",
    "phone": "9876543210", "countryCode": "+91", "profile": "..."
  },
  "LeadActivity": [{
    "id": 555,
    "leadId": 88,
    "Lead": {
      "id": 88, "fname": "Priya", "phone": "9876543210",
      "User": { "id": 101 },
      "LeadSource": { "id": 2 }
    }
  }]
}
```

### Response shape — count endpoints (`/lead-interactions/count`, `/my-lead-interactions/count`)

Aggregates the **entire filtered set** (not just the current page) into dashboard card values.

```json
{
  "total": 42,
  "totalCalls": 120,
  "distinctLeads": 0,
  "connectedCalls": 85,
  "receivedCalls": 90,
  "notConnectedCalls": 35,
  "incomingCalls": 10,
  "outgoingCalls": 110,
  "chatCount": 5,
  "interactionCounts": {
    "call": 60,
    "followup": 0,
    "followup1": 30,
    "followup2": 20,
    "followup3": 10,
    "retention": 0
  },
  "durationSeconds": {
    "totalDial": 18000,
    "totalTalk": 12000,
    "totalRing": 960,
    "longestCall": 600,
    "longestTalk": 540
  },
  "averages": {
    "connectionRate": 0.708,
    "talkPerCall": 100.0,
    "talkPerConnected": 141.2,
    "dialPerCall": 8.0,
    "callsPerLead": 2.86
  },
  "byHour": [0, 0, 0, 0, 0, 0, 0, 0, 5, 18, 22, 20, 15, 12, 10, 8, 5, 3, 2, 0, 0, 0, 0, 0],
  "byHourConnected": [0, 0, 0, 0, 0, 0, 0, 0, 4, 14, 16, 15, 11, 9, 7, 5, 3, 1, 1, 0, 0, 0, 0, 0],
  "byDay": [
    { "date": "2026-06-05", "calls": 60, "connected": 42 },
    { "date": "2026-06-06", "calls": 60, "connected": 43 }
  ],
  "bestHour": { "hour": 10, "calls": 22 }
}
```

**Field notes:**

| Field | Description |
|-------|-------------|
| `total` | Distinct leads touched (not a copy of `totalCalls`). Maps to the **Total Leads** card. |
| `totalCalls` | Total interaction records. Maps to **Total Calls** card. |
| `connectedCalls` | Interactions where `isConnected = true` or `talkDurationSeconds > 0`. |
| `receivedCalls` | Interactions where `callUpTime` is not null — i.e. the call was actually picked up. |
| `notConnectedCalls` | `totalCalls − connectedCalls`. |
| `incomingCalls` / `outgoingCalls` | Split by `isIncomming` flag. |
| `interactionCounts` | Breakdown by follow-up type. Maps to **FU 1 / FU 2 / FU 3** volume cards. |
| `durationSeconds.totalDial` | Sum of full call durations (dial → end). Maps to **Total Dial Time** card. |
| `durationSeconds.totalTalk` | Sum of talk durations (pickup → end). Maps to **Total Talk Time** card. |
| `durationSeconds.totalRing` | Sum of ring durations per call (see `averages.dialPerCall`). |
| `averages.dialPerCall` | **Avg Dial Time** card. Computed as `totalRing / totalCalls`. Ring is `dialTime → pickupTime` when the call was answered, `dialTime → endTime` when it was not. |
| `averages.talkPerCall` | **Avg Talk Duration** card. `totalTalk / totalCalls`. |
| `averages.callsPerLead` | **Avg Calls/Lead** card. `totalCalls / distinctLeads`. |
| `byHour` | 24-element array (index = hour 0–23, IST). Used for **Calls by Hour** bar chart. |
| `byHourConnected` | Same shape as `byHour`, connected calls only. |
| `byDay` | Sorted `{ date: "YYYY-MM-DD", calls, connected }` array. Used for **Daily Trend** chart. |
| `bestHour` | `{ hour, calls }` of the peak hour. Maps to **Best Calling Hour** card. `null` when no calls.
```

---

## 4. Field Mapping (API → UI)

The internal call object the dashboard works with:

| UI field | API source | Notes |
|----------|------------|-------|
| `id` | `interaction.id` | Unique per record |
| `employee.id` | `interaction.employeeId` | |
| `employee.name` | `Employee.fname + " " + Employee.lname` | |
| `employee.init` | `fname[0] + lname[0]` toUpperCase | For avatar display |
| `lead` | `LeadActivity[0].Lead.fname + " " + lname` | Trim trailing space if no lname |
| `phone` | `User.phone` | |
| `dialTime` | `new Date(callDialTime)` | Convert ISO → Date object |
| `ringSeconds` | `ringDurationSeconds ?? 0` | Treat null as 0 |
| `talkSeconds` | `talkDurationSeconds ?? 0` | Treat null as 0 |
| `totalSeconds` | `totalDurationSeconds ?? ringSeconds` | |
| `direction` | `interaction.direction` | ✅ Backend returns `"in"` \| `"out"` (derived from `isIncomming`). |
| `status` | `leadStatusId` | Integer — must match `STATUS_BY_ID` keys |
| `connected` | `interaction.connected` | ✅ Backend returns a boolean (`isConnected`, falling back to talk-time > 0). |
| `followUp` | `interaction.followUpLevel` | ✅ Backend returns `null` \| `1` \| `2` \| `3`. |
| `recordingUrl` | `interaction.recordingUrl` | ✅ Backend returns the recording link or `null`. |

---

## 5. State Variables

All state is module-level JS. No framework, no store.

| Variable | Type / Default | Description |
|----------|---------------|-------------|
| `allCalls` | `Array []` | Master call list. **Replace `genCalls(120)` with real API data.** |
| `curView` | `"admin"` | `"admin"` or `"mine"` — controls which endpoint is called. |
| `curLayout` | `"dash"` | `"dash"` or `"table"` — controls which section is visible. |
| `activeEmp` | `null` | Selected employee ID for leaderboard click-filter. `null` = all. |
| `dateFilter` | `"today"` | `"today"` \| `"yesterday"` \| `"week"` \| `"month"` \| `"custom"` |
| `statusFilter` | `"all"` | Parent status ID (integer) or `"all"` |
| `substatusFilter` | `"all"` | Sub-status ID (integer) or `"all"` |
| `fuFilter` | `"all"` | `"all"` \| `"0"` (fresh only) \| `"1"` \| `"2"` \| `"3"` |
| `dirFilter` | `"all"` | `"all"` \| `"in"` \| `"out"` |
| `connectedOnly` | `false` | If `true`, hides zero-talk-time calls |
| `logPage` | `0` | Zero-based current page for call log. Reset to `0` on filter change. |
| `logSort` | `{key:"time", dir:"desc"}` | Sort state for call log. `key` ∈ `{time, ring, talk, total}` |
| `curLayout` | `"dash"` | `"dash"` \| `"table"` |
| `empTableSort` | `{key:"calls", dir:"desc"}` | Sort state for employee stats table. |

---

## 6. Function Reference

### Data & Filtering

| Function | Action needed | Description |
|----------|---------------|-------------|
| `genCalls(n)` | ⚠️ **REPLACE** | Generates n mock call objects. Replace with `fetchCalls()`. |
| `getFiltered()` | Keep as-is | Pure. Applies all state filters to `allCalls[]`. Called by every render fn. |
| `renderAll()` | Keep as-is | Calls `renderStats()`, `initCharts()`, `renderLeaderboard()`, `renderLog()`. Call after `allCalls[]` is updated. |
| `flattenStatuses(nodes)` | Keep as-is | Builds `STATUS_BY_ID{}` from `STATUS_TREE[]`. Runs once at init. |
| `statusLabel(id)` | Keep as-is | Returns display name for a status ID. |
| `statusColor(id)` | Keep as-is | Returns hex colour, walks up to parent if no direct mapping. |
| `parentStatusId(id)` | Keep as-is | Returns top-level ancestor ID (for donut grouping). |

### Render Functions

| Function | Description |
|----------|-------------|
| `renderStats()` | Computes all 14 card values + highlight cards from `getFiltered()`. Calls `animate()` on each. |
| `initCharts()` | Destroys Chart.js instances + rebuilds hour bar, daily trend, status donut. Must be called after dark mode toggle. |
| `renderLeaderboard()` | Groups filtered calls by employee, sorts by count, renders rows with bars. |
| `renderLog()` | Applies `logSearch`, sorts by `logSort`, paginates at 12/page, renders `tbody`. |
| `renderEmpTable()` | Groups filtered calls by employee, computes per-employee stats, renders table + totals row. |
| `animate(id, val)` | Animates card number from current to `val` over 600ms using `requestAnimationFrame`. |

### Filter Functions

| Function | Description |
|----------|-------------|
| `setMode(v)` | Main toggle: `'all'` \| `'mine'` \| `'table'`. Updates `curView`, `curLayout`, shows/hides sections, calls `renderAll()` or `renderEmpTable()`. |
| `setDateFilter(val, btn)` | Updates `dateFilter`, closes panel, triggers `renderAll()`. |
| `setStatusFilter(val, btn)` | Updates `statusFilter`, resets `substatusFilter`, builds sub-status panel if parent has children, triggers `renderAll()`. |
| `setSubstatusFilter(val, btn)` | Updates `substatusFilter`, triggers `renderAll()`. |
| `setFUFilter(val, btn)` | Updates `fuFilter`, triggers `renderAll()`. |
| `setDirFilter(val, btn)` | Updates `dirFilter`, triggers `renderAll()`. |
| `filterByEmpFilter(id, btn)` | Updates `activeEmp`, updates trigger appearance, triggers `renderAll()`. |
| `toggleConnected()` | Toggles `connectedOnly`, triggers `renderAll()`. |
| `buildStatusFilter()` | Populates `#statusFilterList` from `STATUS_TREE[]`. Called once at init. |
| `buildEmpFilter()` | Populates `#empFilterList` with employee rows + call counts. Called once at init — **update to use real employee list from API.** |

### UI Functions

| Function | Description |
|----------|-------------|
| `playRecording(id)` | Opens inline recording player below the row. Currently simulated. Wire to real audio — see §10. |
| `startPlay(id, dur)` | Starts 100ms interval that advances progress bar + cursor. Replace with `<audio>` event. |
| `stopPlay(id)` | Clears interval, resets play button icon. |
| `togglePlay(id)` | Toggles between `startPlay` and `stopPlay`. |
| `seekRecording(e, id, dur)` | Click on waveform track → seeks to that position. |
| `closePlayer(id)` | Stops playback, removes player row, clears playing state. |
| `toggleDark()` | Adds/removes `body.dark`. Saves to `localStorage["crm-dark"]`. Calls `initCharts()` after 50ms. |
| `openHelp()` / `closeHelp()` | Opens/closes metric definitions modal. |
| `showToast(msg, type)` | Shows bottom toast. `type`: `"success"` \| `"info"` \| `"error"`. |

---

## 7. Filter → API Param Mapping

| UI state | API param | Transformation |
|----------|-----------|----------------|
| `dateFilter = "today"` | `startDate`, `endDate` | `today 00:00 IST` → `today 23:59 IST` |
| `dateFilter = "yesterday"` | `startDate`, `endDate` | `yesterday 00:00` → `yesterday 23:59` |
| `dateFilter = "week"` | `startDate`, `endDate` | `Monday 00:00 IST` → `now` |
| `dateFilter = "month"` | `startDate`, `endDate` | `1st of month 00:00 IST` → `now` |
| `statusFilter` (integer) | `leadStatusIds` | Pass the ID + all descendant IDs. Use `flattenStatuses()` to collect them. |
| `substatusFilter` (integer) | `leadStatusIds` | Pass the sub-status ID + its children only. |
| `activeEmp` (integer) | `employeeIds` | Single-element array. Admin endpoint only. |
| `logPage` (integer) | `page` | Pass directly. API page size = 50, UI = 12. See §8 for handling. |
| `curView = "mine"` | Endpoint switch | Use `/my-lead-interactions`. No `employeeIds` needed. |
| `dirFilter` | `direction` | ✅ Server-side supported (`"in"` / `"out"`). May still filter client-side within a page. |
| `fuFilter` | `interaction` | ✅ Server-side supported. Pass one of: `"call"`, `"followup"`, `"followup1"`, `"followup2"`, `"followup3"`, `"retention"`. Matching is case-insensitive; `"call"` also matches null/empty rows. Omit param for `"all"`. |
| `logSearch` | `search` | ✅ Server-side supported. Pass the raw search string. The backend searches `fname`, `lname`, `email`, `phone` on the interaction's `User` and `Lead`. A string with a space is also matched as `fname + lname`. |
| `connectedOnly` | ❌ No API param | Client-side: `talkDurationSeconds > 0`. |

---

## 8. Integration Steps

### Recommended approach — Hybrid

Fetch on date/status/employee changes (server-side), do direction/FU/connected filtering client-side.

**Step 1 — Replace `genCalls()` with `fetchCalls()`**

```js
const BASE_URL = '{{baseUrl}}/api/command';

function getToken() {
  return localStorage.getItem('employee_jwt'); // adjust to your auth flow
}

function buildAPIParams() {
  const p = new URLSearchParams();

  // Date range
  const { start, end } = getDateRange(dateFilter); // implement this helper
  if (start) p.set('startDate', start.toISOString());
  if (end)   p.set('endDate',   end.toISOString());

  // Status filter — pass selected ID + all descendants
  if (statusFilter !== 'all') {
    const ids = getDescendantIds(statusFilter); // collect from STATUS_BY_ID
    p.set('leadStatusIds', JSON.stringify(ids));
  }

  // Employee filter (admin only)
  if (curView === 'admin' && activeEmp !== null) {
    p.set('employeeIds', JSON.stringify([activeEmp]));
  }

  // Pagination
  p.set('page', String(logPage));

  return p.toString();
}

async function fetchCalls() {
  showLoader(true);
  try {
    const endpoint = curView === 'mine'
      ? '/my-lead-interactions'
      : '/lead-interactions';
    const res = await fetch(`${BASE_URL}${endpoint}?${buildAPIParams()}`, {
      headers: { 'Authorization': `Bearer ${getToken()}` }
    });
    if (!res.ok) throw new Error(res.status);
    const { interactions } = await res.json();
    allCalls = interactions.map(mapInteraction);
    renderAll();
  } catch (e) {
    showToast('Failed to load calls', 'error');
    console.error(e);
  } finally {
    showLoader(false);
  }
}
```

**Step 2 — Helper to collect descendant status IDs**

```js
function getDescendantIds(statusId) {
  const ids = [statusId];
  const node = STATUS_BY_ID[statusId];
  if (node?.subs) {
    node.subs.forEach(sub => {
      ids.push(...getDescendantIds(sub.id));
    });
  }
  return ids;
}
```

**Step 3 — Wire filter changes to API**

Call `fetchCalls()` (not `renderAll()`) when these filters change:
- `setDateFilter()` — date range changes
- `setStatusFilter()` — status changes (pass `leadStatusIds`)
- `filterByEmpFilter()` — employee selection changes
- `setMode()` — view mode changes (different endpoint)
- `refreshData()` — manual refresh

Keep `renderAll()` (client-side only) for:
- `setSubstatusFilter()` — sub-set of already-fetched status data
- `setDirFilter()` — direction (client-side)
- `setFUFilter()` — follow-up level (client-side)
- `toggleConnected()` — talk time check (client-side)
- `logPage` / `sortLog()` changes — paginate within fetched data

**Step 4 — Show loader during fetch**

```js
function showLoader(show) {
  document.getElementById('fetchLoader').classList.toggle('show', show);
}
```

The `#fetchLoader` overlay already exists in the HTML.

**Step 5 — Update `buildEmpFilter()` to use real employees**

```js
async function loadEmployees() {
  // Either fetch from a /employees endpoint
  // or derive unique employees from the first call to /lead-interactions
  const res = await fetch(`${BASE_URL}/employees`, {
    headers: { 'Authorization': `Bearer ${getToken()}` }
  });
  const { employees } = await res.json();
  EMPLOYEES = employees.map(e => ({
    id:   e.id,
    name: `${e.fname} ${e.lname}`,
    init: `${e.fname[0]}${e.lname[0]}`.toUpperCase()
  }));
  buildEmpFilter();
}
```

**Step 6 — Page size mismatch**

API returns 50 per page. Dashboard shows 12 per page. Options:

| Option | Approach |
|--------|----------|
| **A (simpler)** | Fetch all 50 records per API page. Client paginates within those 50 at 12/page. Re-fetch when `logPage >= 4`. |
| **B (accurate)** | Always pass `Math.floor(logPage * 12 / 50)` as API `page`. Re-fetch on every `logPage` change. |

Option A is recommended for now.

---

## 9. `mapInteraction()` Implementation

Copy this and adjust field names once confirmed with backend:

```js
function mapInteraction(i) {
  const emp  = i.Employee;
  const lead = i.LeadActivity?.[0]?.Lead;
  const user = i.User;

  const talkSec  = i.talkDurationSeconds  ?? 0;
  const ringSec  = i.ringDurationSeconds  ?? 0;
  const totalSec = i.totalDurationSeconds ?? ringSec;

  return {
    id:       i.id,
    employee: {
      id:   emp.id,
      name: `${emp.fname} ${emp.lname}`.trim(),
      init: `${emp.fname[0]}${emp.lname[0]}`.toUpperCase(),
    },
    lead:        lead ? `${lead.fname} ${lead.lname ?? ''}`.trim() : 'Unknown',
    phone:       user?.phone ?? '—',
    dialTime:    new Date(i.callDialTime),
    ringSeconds: ringSec,
    talkSeconds: talkSec,
    totalSeconds: totalSec,

    // ⚠️ Confirm field names for these three:
    direction:    i.direction     ?? 'out',       // "in" | "out"
    status:       i.leadStatusId,                  // integer → STATUS_BY_ID key
    connected:    talkSec > 0,                     // derived
    followUp:     i.followUpLevel ?? null,          // null | 1 | 2 | 3
    recordingUrl: i.recordingUrl  ?? null,          // string URL or null
  };
}
```

---

## 10. Recording Player Wiring

Currently simulated with a 100ms `setInterval`. Replace `startPlay()` with real `<audio>`:

```js
const audioInstances = {}; // store per call ID

function playRecording(id) {
  const r = allCalls.find(x => x.id === id);
  if (!r) return;

  if (!r.recordingUrl) {
    showToast('No recording available', 'info');
    return;
  }

  // Close existing players
  document.querySelectorAll('.rec-player-row').forEach(el => el.remove());
  document.querySelectorAll('.play-btn.playing').forEach(b => b.classList.remove('playing'));
  if (audioInstances[playerActiveId]) {
    audioInstances[playerActiveId].pause();
    delete audioInstances[playerActiveId];
  }
  if (playerActiveId === id) { playerActiveId = null; return; }

  playerActiveId = id;

  // Build player row UI (existing code handles this)
  // ...after player row is inserted:

  const audio = new Audio(r.recordingUrl);
  audioInstances[id] = audio;
  audio.play();

  audio.addEventListener('timeupdate', () => {
    const pct = (audio.currentTime / audio.duration) * 100;
    document.getElementById(`rpFill_${id}`).style.width  = pct + '%';
    document.getElementById(`rpCur_${id}`).style.left    = pct + '%';
    const s = Math.floor(audio.currentTime);
    document.getElementById(`rpTime_${id}`).textContent  =
      `${Math.floor(s / 60)}:${(s % 60 < 10 ? '0' : '')}${s % 60}`;
  });

  audio.addEventListener('ended', () => stopPlay(id));
}

function seekRecording(e, id, dur) {
  const rect = e.currentTarget.getBoundingClientRect();
  const pct  = (e.clientX - rect.left) / rect.width;
  if (audioInstances[id]) {
    audioInstances[id].currentTime = pct * audioInstances[id].duration;
  }
}
```

---

## 11. Follow-Up Level — Backend Requirement

✅ **Implemented (Option A).** Each interaction response now includes `followUpLevel: null | 1 | 2 | 3`. Map it directly in `mapInteraction()`:

```js
followUp: i.followUpLevel ?? null,
```

The notes below are retained for reference.

**Option A — Backend adds field (implemented)**  
`followUpLevel: null | 1 | 2 | 3` is computed from the lead's full done-call history (not just the current page): 1st call = null, 2nd call = FU1, 3rd = FU2, 4th+ = FU3 (capped).

**Option B — Client derives from response**  
After fetching all interactions, group by `leadId`, sort by `callDialTime`, assign level by position.

```js
function assignFollowUpLevels(interactions) {
  const leadCalls = {};
  // Sort by time ascending
  const sorted = [...interactions].sort((a, b) =>
    new Date(a.callDialTime) - new Date(b.callDialTime)
  );
  sorted.forEach(i => {
    const lid = i.LeadActivity?.[0]?.Lead?.id;
    if (!lid) return;
    leadCalls[lid] = (leadCalls[lid] ?? 0) + 1;
    const count = leadCalls[lid];
    i._followUpLevel = count === 1 ? null : Math.min(count - 1, 3);
  });
  return interactions; // mutated in place
}
```

Then in `mapInteraction()`: `followUp: i._followUpLevel ?? null`

---

## 12. Status Tree

`STATUS_TREE[]` is hardcoded from `UserLeadStatus.csv` (74 rows, `action = "lead"`).

### Structure

```
No Contact (6)
  ├── No Contact 1 (7)
  │     ├── RNR (10), Switched Off (13), Picked & Cut (16)
  │     ├── Network Issue (45), Fwd to Voicemail (53), Busy (59)
  ├── No Contact 2 (8) → same sub-statuses as NC1
  ├── No Contact 3 (9) → same sub-statuses
  └── No Contact 4 (46) → same sub-statuses

Interested (19)
  ├── Hot (20), Cold (21), Warm (22)

Deferred Hot (23)
  ├── Price Problem (24), Next Batch (25)

Not Interested (26)
  ├── Not Interested in Course (27), Not Interested in ABC (28)

Non Workable (29)
  ├── Dual Device (30), Live Classes Only (31)
  ├── English Only (32), International Number (33)

Invalid Lead (34)
  ├── Language Barrier (35), No Idea About Course (36)
  ├── Did Not Fill Form (37), Invalid Number (38)
  ├── Abusive (39), Looking for Jobs (40)
  ├── Incoming Unavailable (57), Wrong Number (58)

Career Enquiry (2)
  ├── CFA GQ (3), FRM GQ (4), Excel GQ (5)
  ├── Query Resolved (63), Need AB's Guidance (64)

New Enquiry (1) · Converted (41) · New Course Enquiry (42)
Already Enrolled (43) · Call Back Later (44)
Repeat Enquiry (65) · Not Connected 8+ (66)
```

### Helper functions

| Function | Usage |
|----------|-------|
| `STATUS_BY_ID[id]` | O(1) lookup. Returns `{id, name, parentId, subs[]}`. |
| `statusLabel(id)` | Display name. Used in log table and donut legend. |
| `statusColor(id)` | Hex colour. Walks up to parent if no direct match. |
| `parentStatusId(id)` | Top-level ancestor ID. Used for donut chart grouping. |

> **Note:** If statuses change in the DB, update `STATUS_TREE[]` in the script. Consider fetching from an API endpoint if the list changes frequently.

---

## 13. Open Items — Confirm with Backend

| # | Item | Required action |
|---|------|----------------|
| 1 | **Call direction field** | ✅ Resolved. Backend returns `direction: "in" \| "out"` (derived from `isIncomming`). |
| 2 | **Follow-up level field** | ✅ Resolved (Option A). Backend returns `followUpLevel: null\|1\|2\|3`, computed from the lead's full done-call history. |
| 3 | **Recording URL field** | ✅ Resolved. Backend returns `recordingUrl` (string or null) from the uploaded recording link. |
| 4 | **Employee list endpoint** | Need `/employees` endpoint OR derive employee list from interaction responses. |
| 5 | **Auth token location** | Where is the JWT stored? Adjust `getToken()` accordingly. |
| 6 | **Page size handling** | API = 50/page, UI = 12/page. Decide on Option A or B from §8. |
| 7 | **Direction server-side** | ✅ Resolved. Pass `direction=in\|out` as a query param (see §3 / §7). |
| 8 | **Lead full name** | Is `lname` always present on `LeadActivity[0].Lead`? Or fname only? |
| 9 | **Interaction type filter** | ✅ Resolved. Pass `interaction=call\|Call\|followup\|followup1\|followup2\|followup3\|retention` as a query param (see §3 / §7). Count endpoint returns `interactionCounts` keyed by these values instead of the old `followUp` bucket. |
| 10 | **Search filter** | ✅ Resolved. Pass `search=<string>` — backend searches fname/lname/email/phone on both `User` and `Lead`. Space-separated string also matches as fname+lname (see §3 / §7). |
| 11 | **List sort order** | ✅ Resolved. Both list endpoints (`/lead-interactions`, `/my-lead-interactions`) now return records ordered by `updatedAt DESC`. |

---

## Quick Checklist

```
[ ] Replace genCalls(120) with fetchCalls()
[ ] Implement mapInteraction() with correct field names
[ ] Implement buildAPIParams() with date/status/employee/interaction/search mapping
[ ] Wire setDateFilter(), setStatusFilter(), filterByEmpFilter(), setMode() → fetchCalls()
[ ] Wire setFUFilter() → fetchCalls() with interaction param (now server-side)
[ ] Wire logSearch → fetchCalls() with search param (now server-side)
[ ] Handle loading state with showLoader()
[ ] Load real employee list for dropdown
[ ] Confirm + implement: direction, followUpLevel, recordingUrl fields
[ ] Wire recording player to real Audio API
[ ] Handle API errors gracefully with showToast()
[ ] Test dark mode (charts auto-reinit on toggle)
[ ] Test all 3 view modes: All / My Calls / Employee Table
```

---

*UXL CRM · Leveraged Growth Pvt Ltd · June 2026 · Confidential — Developer Use Only*
