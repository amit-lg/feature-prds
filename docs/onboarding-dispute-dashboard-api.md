# Onboarding & Dispute Dashboard — API Reference

**Project:** UXL CRM — Leveraged Growth Pvt Ltd  
**Module:** Command (Employee-facing)  
**Date:** June 2026  
**Status:** API Complete

---

## Table of Contents

1. [Overview](#1-overview)
2. [API Endpoints](#2-api-endpoints)
3. [Query Parameters](#3-query-parameters)
4. [Response Shapes](#4-response-shapes)
5. [Permission Gates](#5-permission-gates)
6. [Frontend Integration Notes](#6-frontend-integration-notes)

---

## 1. Overview

The Onboarding & Dispute Dashboard gives onboarding employees a unified view of **post-sale users** — people who have already paid — and manages the structured call sequences that ensure those users successfully activate. The workflow is driven by call types and resolution states.

### What the Dashboard Shows

| Section | Description |
|---------|-------------|
| **Onboarding Users list** | Paginated list of `UserPayments` — enrolled users with billing, shipping, cart details |
| **Active Call Queue** | Batch of calls assigned to the employee (zeroday / sevenday / thirtyday) |
| **Disputed Calls Queue** | Users flagged as `onboardingDispute.isComplete = false` in their MetaHistory |
| **Scheduled Calls Queue** | Users with a past `appointmentTime` that hasn't been called yet |
| **Call Log** | Device-scoped log of all onboarding interactions (not linked to leads) |
| **Single User View** | Deep view of one user: payment, billing, shipping, courses, call history |

### View Modes

| Tab | Primary Endpoint | Permission |
|-----|-----------------|------------|
| Analytics (All) | `/onboarding-interactions` + `/onboarding-interactions/count` | `canViewOnboardingDashboard` |
| Analytics (Mine) | `/my-onboarding-interactions` + `/my-onboarding-interactions/count` | `canViewSelfOnboardingDashboard` |
| Users | `/onboarding-users` | `canViewOnboardingUsers` |
| My Calls | `/onboarding-calls` | `canDoOnboardingCalls` |
| Disputed | `/disputed-onboarding-calls` | `canViewDisputedCalls` |
| Scheduled | `/scheduled-onboarding-calls` | `canDoOnboardingCalls` |
| Call Log | `/onboarding-call-log` | `canViewSelfOnboardingDashboard` |

---

## 2. API Endpoints

**Base URL:** `{{baseUrl}}/api/command`  
**Auth:** `Authorization: Bearer <employee_jwt>` on every request.

### Interaction Analytics

| Method | Endpoint | Permission | Description |
|--------|----------|------------|-------------|
| `GET` | `/onboarding-interactions` | `canViewOnboardingDashboard` | Paginated list of all onboarding interactions |
| `GET` | `/onboarding-interactions/count` | `canViewOnboardingDashboard` | Aggregate stats — byHour, byDay, purposeCounts |
| `GET` | `/my-onboarding-interactions` | `canViewSelfOnboardingDashboard` | Own paginated interaction list |
| `GET` | `/my-onboarding-interactions/count` | `canViewSelfOnboardingDashboard` | Own aggregate stats |

### Users

| Method | Endpoint | Permission | Description |
|--------|----------|------------|-------------|
| `GET` | `/onboarding-users` | `canViewOnboardingUsers` | Paginated list of user payments |
| `GET` | `/onboarding-users/count` | `canViewOnboardingUsers` | Count of matching user payments |
| `GET` | `/onboarding-user/:id` | `canViewSelfOnboardingDashboard` | Full detail for one user by `userId` |
| `PATCH` | `/onboarding-user-billing/:id` | `canViewSelfOnboardingDashboard` | Update billing info for a user |
| `PATCH` | `/onboarding-user-shipping/:id` | `canViewSelfOnboardingDashboard` | Update shipping info for a user |

### Call Queues

| Method | Endpoint | Permission | Description |
|--------|----------|------------|-------------|
| `GET` | `/onboarding-calls` | `canDoOnboardingCalls` | Pull a batch of onboarding calls by type |
| `GET` | `/disputed-onboarding-calls` | `canViewDisputedCalls` | Pull disputed onboarding calls |
| `GET` | `/scheduled-onboarding-calls` | `canDoOnboardingCalls` | Pull scheduled appointment calls due today |
| `GET` | `/onboarding-calls/:interactionId` | `canViewSelfOnboardingDashboard` | Detail for a single onboarding call interaction |

### Call Lifecycle

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/onboarding-dial-number` | Initiate an outbound call |
| `POST` | `/onboarding-came-call` | Log an incoming call |
| `POST` | `/onboarding-call-pickup` | Notify call was picked up |
| `POST` | `/onboarding-end-call` | Notify call ended |
| `PATCH` | `/onboarding-call-start` | Start the call timer |
| `PATCH` | `/onboarding-call-pickedup/:interactionId` | Mark call as picked up |
| `PATCH` | `/onboarding-call-again/:interactionId` | Re-dial / call again |
| `PATCH` | `/onboarding-call-ended/:interactionId` | Mark call as ended |
| `POST` | `/onboarding-call/:interactionId` | Save call outcome (remarks, status, form fields) |
| `POST` | `/onboarding-interaction` | Add a manual interaction record |

### Search & Log

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/onboarding-search-user` | Search a user by name/phone before calling |
| `GET` | `/search-onboarding-users` | Search across all onboarding call users |
| `GET` | `/onboarding-call-log` | Device-scoped log of all onboarding interactions |
| `GET` | `/dissolve-onboarding-calls` | Mark all pending calls as dissolved |
| `GET` | `/onboarding-lead-status` | Fetch the `OnboardingCallStatus` list |

### Dispute

| Method | Endpoint | Permission | Description |
|--------|----------|------------|-------------|
| `POST` | `/onboarding-dispute` | `canViewSelfOnboardingDashboard` | Flag a user as having an onboarding dispute |
| `POST` | `/manual-calling` | `canViewSelfOnboardingDashboard` | Add a manual call for a specific purpose |

---

## 3. Query Parameters

### `GET /onboarding-interactions`, `/onboarding-interactions/count`, `/my-onboarding-interactions`, `/my-onboarding-interactions/count`

| Param | Type | Description |
|-------|------|-------------|
| `employeeIds` | `number[]` | Admin endpoints only. JSON array or comma-separated. Ignored on `/my-*` endpoints. |
| `startDate` | ISO string | Normalised to IST 00:00. Filters on `callDialTime`. |
| `endDate` | ISO string | Normalised to IST 23:59. |
| `purpose` | string | `"zeroday"` \| `"sevenday"` \| `"thirtyday"` \| `"disputedOnboardingCall"` \| `"onboarding-appointment"`. Omit for all. |
| `search` | string | Searches `User.fname`, `lname`, `phone`, `email`. |
| `page` | number | Zero-based. 50 records per page. (List endpoints only.) |

### `GET /onboarding-users` and `/onboarding-users/count`

| Param | Type | Description |
|-------|------|-------------|
| `searchString` | string | Free-text search across `fname`, `lname`, `email`, `phone` |
| `searchType` | `"name"` \| `"email"` \| `"phone"` \| `"address"` | Type of search |
| `startDate` | ISO string | Filter by payment `createdAt` start date |
| `endDate` | ISO string | Filter by payment `createdAt` end date |
| `courseId` | number | Filter by enrolled course |
| `page` | number | Zero-based; 50 records per page |
| `paymentId` | number | Return a specific payment by ID |
| `city` | string | Filter by shipping/billing city |
| `state` | string | Filter by state |
| `country` | string | Filter by country |
| `deviceType` | `"Windows"` \| `"MacOs"` \| `"iOS"` \| `"Android"` | Filter by user's device type |
| `expiryStartDate` | ISO string | Filter by course access expiry start |
| `expiryEndDate` | ISO string | Filter by course access expiry end |
| `hasPendrive` | boolean | Filter users who have/don't have a pendrive |
| `hasGst` | boolean | Filter users who have GST billing |
| `paymentMode` | `"online"` \| `"manual"` | Filter by payment mode |
| `status` | `"success"` \| `"pending"` \| `"awaited"` \| `"manual"` \| `"cancelled"` | Filter by payment status |

### `GET /onboarding-calls`

| Param | Type | Description |
|-------|------|-------------|
| `callType` | `"zeroday"` \| `"sevenday"` \| `"thirtyday"` | Required. Which onboarding call batch to pull |
| `courseIds` | `number[]` | JSON array. Filter users by enrolled course IDs |
| `count` | number | Max calls to pull (default 50, max 50) |

### `GET /disputed-onboarding-calls` and `GET /scheduled-onboarding-calls`

| Param | Type | Description |
|-------|------|-------------|
| `count` | number | Max calls to pull (default 50, max 50) |

### `GET /onboarding-call-log`

| Param | Type | Description |
|-------|------|-------------|
| `deviceId` | string | Required. The employee's device ID |
| `page` | number | Zero-based; 50 records per page |

### `GET /search-onboarding-users`

| Param | Type | Description |
|-------|------|-------------|
| `searchString` | string | Free-text |
| `page` | number | Zero-based; 50 records per page |

---

## 4. Response Shapes

### `/onboarding-interactions` and `/my-onboarding-interactions`

Each record is run through the same derived-field logic as the lead-admin
calling dashboard's `/lead-interactions` (see [lead-admin-api.md](lead-admin-api.md)),
so the two list responses have matching call-timing shapes.

```json
{
  "interactions": [
    {
      "id": 5001,
      "userId": 55,
      "employeeId": 7,
      "purpose": "zeroday",
      "isDone": null,
      "callDialTime": "2026-06-10T04:00:00.000Z",
      "callUpTime": "2026-06-10T04:00:10.000Z",
      "callEndTime": "2026-06-10T04:05:30.000Z",
      "isIncomming": false,
      "isConnected": true,
      "mode": "call",
      "files": { "link": "https://.../onboarding_recording_5001_....mp3" },
      "ringDurationSeconds": 10,
      "talkDurationSeconds": 320,
      "totalDurationSeconds": 330,
      "direction": "out",
      "connected": true,
      "recordingUrl": "https://.../onboarding_recording_5001_....mp3",
      "Employee": {
        "id": 7, "fname": "Asha", "lname": "Rao",
        "email": "asha@example.com", "profile": "https://..."
      },
      "User": {
        "id": 55, "fname": "Priya", "lname": "Sharma",
        "email": "priya@example.com", "phone": "9876543210",
        "countryCode": "+91", "profile": "https://..."
      }
    }
  ]
}
```

**Derived fields** (attached server-side, not raw columns):

| Field | Description |
|-------|--------------|
| `ringDurationSeconds` | `dialTime → pickupTime` when answered, else `dialTime → endTime`. `0` if neither timestamp pair is present. |
| `talkDurationSeconds` | `pickupTime → endTime`. `0` when the call was never picked up. |
| `totalDurationSeconds` | `dialTime → endTime`, falling back to `pickupTime → endTime` (incoming calls with no dial time), falling back to `ringDurationSeconds`. |
| `direction` | `"in"` when `isIncomming === true`, else `"out"`. |
| `connected` | `isConnected` if set, else `talkDurationSeconds > 0`. |
| `recordingUrl` | `files.link` or `null`. |

### `/onboarding-interactions/count` and `/my-onboarding-interactions/count`

```json
{
  "total": 120,
  "totalCalls": 340,
  "connectedCalls": 210,
  "receivedCalls": 225,
  "notConnectedCalls": 130,
  "incomingCalls": 15,
  "outgoingCalls": 325,
  "chatCount": 4,
  "purposeCounts": {
    "zeroday": 150,
    "sevenday": 100,
    "thirtyday": 60,
    "disputedOnboardingCall": 20,
    "onboarding-appointment": 10
  },
  "inProgressCounts": {
    "zeroday": 12,
    "sevenday": 8,
    "thirtyday": 4
  },
  "durationSeconds": {
    "totalDial": 42000,
    "totalTalk": 30500,
    "totalRing": 2800,
    "longestCall": 900,
    "longestTalk": 780
  },
  "averages": {
    "connectionRate": 0.618,
    "talkPerCall": 89.7,
    "talkPerConnected": 145.2,
    "dialPerCall": 8.2,
    "callsPerUser": 2.83
  },
  "pendingCounts": {
    "zeroday": 32,
    "sevenday": 18,
    "thirtyday": 9
  },
  "byHour": [0, 0, 0, 0, 0, 0, 0, 2, 18, 42, 55, 48, 30, 25, 20, 18, 12, 8, 5, 2, 0, 0, 0, 0],
  "byHourConnected": [0, 0, 0, 0, 0, 0, 0, 1, 12, 28, 38, 35, 22, 18, 14, 12, 8, 5, 3, 1, 0, 0, 0, 0],
  "byDay": [
    { "date": "2026-06-09", "calls": 160, "connected": 100 },
    { "date": "2026-06-10", "calls": 180, "connected": 110 }
  ],
  "bestHour": { "hour": 10, "calls": 55 }
}
```

**Field notes:**

| Field | Description |
|-------|-------------|
| `total` | Distinct users touched (not a copy of `totalCalls`). |
| `totalCalls` | Total interaction records in the filtered set. |
| `connectedCalls` | Interactions where `isConnected = true` or `talkDurationSeconds > 0`. |
| `receivedCalls` | Interactions where `callUpTime` is not null — i.e. the call was actually picked up. |
| `notConnectedCalls` | `totalCalls − connectedCalls`. |
| `incomingCalls` / `outgoingCalls` | Split by `isIncomming` flag. |
| `chatCount` | Interactions where `mode === "chat"`. |
| `purposeCounts` | Total calls made per purpose. |
| `inProgressCounts` | Per-purpose count where `isDone = null` — assigned but not yet completed. |
| `durationSeconds.totalDial` | Sum of full call durations (dial → end). |
| `durationSeconds.totalTalk` | Sum of talk durations (pickup → end). |
| `durationSeconds.totalRing` | Sum of ring durations per call (see `averages.dialPerCall`). |
| `durationSeconds.longestCall` / `longestTalk` | Longest single call/talk duration in the filtered set. |
| `averages.connectionRate` | `connectedCalls / totalCalls`. |
| `averages.dialPerCall` | `totalRing / totalCalls`. Ring is `dialTime → pickupTime` when the call was answered, `dialTime → endTime` when it was not. |
| `averages.talkPerCall` | `totalTalk / totalCalls`. |
| `averages.talkPerConnected` | `totalTalk / connectedCalls`. |
| `averages.callsPerUser` | `totalCalls / total` (distinct users). Onboarding equivalent of the calling dashboard's `averages.callsPerLead` — there's no "lead" concept here, so it's keyed per user instead. |
| `pendingCounts` | Students not yet called at all, per call type. Always relative to today — not affected by `startDate`/`endDate`. |
| `byHour` | 24-element array (index = IST hour 0–23). Total calls per hour. |
| `byHourConnected` | Same shape, connected calls only. |
| `byDay` | Sorted `{ date: "YYYY-MM-DD", calls, connected }`. Based on `callDialTime` in IST. |
| `bestHour` | Peak hour by total calls. `null` if no calls have a `callDialTime`. |

> **Note:** `connectedCalls` previously meant "call was picked up" (`callUpTime != null`). It now matches the calling dashboard's stricter definition (`isConnected` flag, falling back to talk time), and the old pickup-based count is exposed separately as `receivedCalls`. If a consuming frontend was reading `connectedCalls` expecting the old semantics, switch it to `receivedCalls`.

### `/onboarding-users`

```json
{
  "message": "Users Fetched Successfully!",
  "payments": [
    {
      "id": 1001,
      "userId": 55,
      "status": "success",
      "paymentMode": "online",
      "createdAt": "2026-06-01T07:00:00.000Z",
      "User": {
        "fname": "Priya",
        "lname": "Sharma",
        "email": "priya@example.com",
        "phone": "9876543210",
        "countryCode": "+91",
        "profile": "https://...",
        "Meta": { "deviceType": "Windows", "city": "Mumbai" }
      },
      "Billing": {
        "id": 201,
        "name": "Priya Sharma",
        "gst": "27ABCDE1234F1Z5",
        "Company": { "id": 10, "name": "ABC Corp" }
      },
      "Shipping": {
        "id": 301,
        "address": "12 MG Road",
        "city": "Mumbai",
        "state": "Maharashtra",
        "pincode": "400001"
      },
      "Cart": {
        "id": 401,
        "ExtraOptions": [{ "ExtraOption": { "name": "Pendrive", "price": 2000 } }],
        "Course": { "Course": { "Course": { "id": 5, "name": "CFA Level 1" } } }
      }
    }
  ]
}
```

### `/onboarding-users/count`

```json
{ "message": "Count Fetched Successfully!", "count": 1245 }
```

### `/onboarding-calls`, `/disputed-onboarding-calls`, `/scheduled-onboarding-calls`

Returns an array of `UserLeadInteraction` records:

```json
[
  {
    "id": 5001,
    "userId": 55,
    "employeeId": 7,
    "purpose": "zeroday",
    "isDone": null,
    "callDialTime": null,
    "callUpTime": null,
    "callEndTime": null,
    "fieldsJson": {},
    "User": {
      "fname": "Priya",
      "lname": "Sharma",
      "email": "priya@example.com",
      "phone": "9876543210",
      "countryCode": "+91"
    },
    "Enrollment": {
      "Enrollment": {
        "Course": { "Course": { "id": 5, "name": "CFA Level 1" } }
      }
    }
  }
]
```

**Idempotency note (`/onboarding-calls`):** If the employee already has `isDone: null` interactions for the requested `purpose`, the server returns those instead of creating new ones.

**`/disputed-onboarding-calls`:** `purpose` is `"disputedOnboardingCall"`. Includes users where `MetaHistory` has `field: "onboardingDispute"` with `valueJson.isComplete = false`.

**`/scheduled-onboarding-calls`:** `purpose` is `"onboarding-appointment"`. Pulled from interactions where `fieldsJson.appointmentTime <= now`.

### `/onboarding-call-log`

```json
{
  "givingUsers": [
    {
      "fname": "Rahul",
      "lname": "Verma",
      "email": "rahul@example.com",
      "phone": "9123456789",
      "countryCode": "+91",
      "profile": "https://...",
      "EmployeeFname": "Asha",
      "EmployeeLname": "Rao",
      "EmployeeEmail": "asha@example.com",
      "EmployeeProfile": "https://...",
      "dialTime": "2026-06-10T09:30:00.000Z",
      "callUpTime": "2026-06-10T09:30:08.000Z",
      "callEndTime": "2026-06-10T09:32:30.000Z",
      "isIncomming": false,
      "files": {}
    }
  ]
}
```

---

## 5. Permission Gates

| Permission | Gates |
|------------|-------|
| `canViewOnboardingDashboard` | All-employee analytics tabs: `/onboarding-interactions`, `/onboarding-interactions/count` |
| `canViewSelfOnboardingDashboard` | Own analytics tabs: `/my-onboarding-interactions`, `/my-onboarding-interactions/count`; single user view; call log; dispute/manual-calling endpoints |
| `canViewOnboardingUsers` | Users tab and users count — hide tab entirely if missing |
| `canDoOnboardingCalls` | My Calls tab, Scheduled tab — hide if missing |
| `canViewDisputedCalls` | Disputed tab — hide if missing |

Check once on login and store as boolean flags. The server enforces permissions on every request and returns `403 Forbidden` if the employee lacks the required permission.

---

## 6. Frontend Integration Notes

The onboarding interaction endpoints now return the same call-timing/aggregate
shape as the calling dashboard's lead interactions (see
[lead-admin-api.md §4](lead-admin-api.md#4-field-mapping-api--ui) /
[§9](lead-admin-api.md#9-mapinteraction-implementation)), so the two
dashboards can share mapping/rendering code where it makes sense.

**Mapping a list row** (`/onboarding-interactions`, `/my-onboarding-interactions`):

```js
function mapOnboardingInteraction(i) {
  return {
    id:           i.id,
    userId:       i.userId,
    employee:     i.Employee ? { id: i.Employee.id, name: `${i.Employee.fname} ${i.Employee.lname}`.trim() } : null,
    user:         i.User ? { id: i.User.id, name: `${i.User.fname} ${i.User.lname ?? ''}`.trim(), phone: i.User.phone } : null,
    purpose:      i.purpose,
    dialTime:     i.callDialTime ? new Date(i.callDialTime) : null,
    ringSeconds:  i.ringDurationSeconds,
    talkSeconds:  i.talkDurationSeconds,
    totalSeconds: i.totalDurationSeconds,
    direction:    i.direction,     // "in" | "out"
    connected:    i.connected,     // boolean
    recordingUrl: i.recordingUrl,  // string | null
  };
}
```

**Rendering the count/aggregate cards** — key field paths for the dashboard's stat cards, mirroring the calling dashboard's card set:

| Card | Field path |
|------|------------|
| Total Users | `total` |
| Total Calls | `totalCalls` |
| Connected / Not Connected | `connectedCalls` / `notConnectedCalls` |
| Received (picked up) | `receivedCalls` |
| Incoming / Outgoing | `incomingCalls` / `outgoingCalls` |
| Total Dial / Talk Time | `durationSeconds.totalDial` / `durationSeconds.totalTalk` |
| Longest Call / Talk | `durationSeconds.longestCall` / `durationSeconds.longestTalk` |
| Connection Rate | `averages.connectionRate` |
| Avg Talk Duration | `averages.talkPerCall` |
| Avg Dial Time | `averages.dialPerCall` |
| Avg Calls / User | `averages.callsPerUser` |
| Calls by Hour chart | `byHour` / `byHourConnected` |
| Daily Trend chart | `byDay` |
| Best Calling Hour | `bestHour` |
| Per-purpose breakdown | `purposeCounts`, `inProgressCounts`, `pendingCounts` |

**Breaking change to watch for:** if an existing frontend build already reads
`connectedCalls` expecting "call was picked up" semantics, repoint it at the
new `receivedCalls` field — `connectedCalls` now means `isConnected`/talk-time
based, matching the calling dashboard.

---

*UXL CRM · Leveraged Growth Pvt Ltd · June 2026*
