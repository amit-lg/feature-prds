# Onboarding Payments Dashboard — API Reference

**Project:** UXL CRM — Leveraged Growth Pvt Ltd
**Module:** Command (Employee-facing)
**Date:** July 2026
**Status:** API Complete

---

## Table of Contents

1. [Overview](#1-overview)
2. [API Endpoint](#2-api-endpoint)
3. [Query Parameters](#3-query-parameters)
4. [Response Shape](#4-response-shape)
5. [Permission Gate](#5-permission-gate)
6. [Frontend Integration Notes](#6-frontend-integration-notes)

---

## 1. Overview

The Onboarding Payments Dashboard summarizes successful payments/enrollments over
a date range: how many students paid and enrolled, what device they bought for,
where they're from (country/state), and whether they were enrolled through a
call-center employee or self-checked-out.

This is a single stats endpoint — no pagination, no per-student list. It
computes everything from `UserPayments` rows with `status: 'success'`.

---

## 2. API Endpoint

**Base URL:** `{{baseUrl}}/api/command`
**Auth:** `Authorization: Bearer <employee_jwt>`

| Method | Endpoint | Permission | Description |
|--------|----------|------------|-------------|
| `GET` | `/onboarding-dashboard` | `canViewOnboardingUsers` OR `canViewOnboardingUsersDashboard` | Aggregate onboarding payment stats for a date range |

---

## 3. Query Parameters

| Param | Type | Description |
|-------|------|-------------|
| `startDate` | ISO string | Optional. Normalised to IST 00:00:00. Filters on `UserPayments.createdAt`. |
| `endDate` | ISO string | Optional. Normalised to IST 23:59:59. |
| `courseIds` | `number[]` | Optional. JSON array or comma-separated. Matches the payment's cart against the course (or up to 3 levels of course-bundle nesting). |
| `deviceTypes` | `string[]` | Optional. JSON array or comma-separated. One or more of `"Windows"`, `"MacOs"`, `"iOS"`, `"Android"`. Matches carts that include a matching device `ExtraOption`. |

Omitting `startDate`/`endDate` returns stats across all time (still scoped to
the caller's `platformId`).

**Example:**
```
GET /api/command/onboarding-dashboard?startDate=2026-06-01&endDate=2026-06-30&courseIds=[5,12]&deviceTypes=Windows,Android
```

---

## 4. Response Shape

```json
{
  "message": "Onboarding dashboard fetched successfully",
  "range": {
    "startDate": "2026-06-01T00:00:00.000+05:30",
    "endDate": "2026-06-30T23:59:59.999+05:30"
  },
  "summary": {
    "paymentsCount": 340,
    "studentsCount": 322,
    "enrollmentsCount": 355
  },
  "deviceBreakdown": {
    "Windows": 180,
    "Android": 90,
    "iOS": 40,
    "MacOs": 20,
    "Unknown": 10
  },
  "countryBreakdown": [
    { "key": "India", "count": 310 },
    { "key": "United States", "count": 20 },
    { "key": "Unknown", "count": 10 }
  ],
  "stateBreakdown": [
    { "key": "Maharashtra", "count": 90 },
    { "key": "Delhi", "count": 60 },
    { "key": "Unknown", "count": 15 }
  ],
  "enrolledBy": {
    "self": 210,
    "employeeAssisted": 130
  }
}
```

**Field notes:**

| Field | Description |
|-------|--------------|
| `summary.paymentsCount` | Successful `UserPayments` rows in range/filters. |
| `summary.studentsCount` | Distinct `userId` among those payments (a student who paid twice counts once). |
| `summary.enrollmentsCount` | Distinct course enrollments (`PaymentToEnrollment` rows) tied to those payments. |
| `deviceBreakdown` | Count of payments whose cart included that device option. A cart with multiple devices selected counts toward each; `"Unknown"` is payments with no device `ExtraOption`. |
| `countryBreakdown` / `stateBreakdown` | From `UserPayments.Billing.country` / `.state`, sorted descending by count. `"Unknown"` when billing has no value. |
| `enrolledBy.self` | Payment has no traceable `Lead` (straight self-checkout, no call-center involvement). |
| `enrolledBy.employeeAssisted` | Payment traces back through `LeadActivity → Lead` to a lead with an assigned `employeeId`. |

---

## 5. Permission Gate

| Permission | Gates |
|------------|-------|
| `canViewOnboardingUsers` or `canViewOnboardingUsersDashboard` | `/onboarding-dashboard` (either permission is sufficient) |

Same gate as `/onboarding-users` and `/onboarding-users/count` — if the employee
already sees the Users tab, they can see this dashboard.

---

## 6. Frontend Integration Notes

- **Stat cards:** `summary.paymentsCount`, `summary.studentsCount`, `summary.enrollmentsCount`.
- **Device chart:** render `deviceBreakdown` directly as a pie/bar — it's already `{ name: count }`.
- **Country/state charts:** `countryBreakdown` / `stateBreakdown` are pre-sorted arrays of `{ key, count }` — map `key` to the label and `count` to the value, no client-side sorting needed.
- **Self vs employee-assisted:** `enrolledBy.self` + `enrolledBy.employeeAssisted` should equal `summary.paymentsCount` — use as a 2-slice donut.
- **Filtering:** applying `deviceTypes` narrows the whole response (not just `deviceBreakdown`) — e.g. filtering to `Android` will shrink `summary.paymentsCount` to Android-only payments too, and `deviceBreakdown` will show only `{ Android: N }`. Same for `courseIds`.

---

*UXL CRM · Leveraged Growth Pvt Ltd · July 2026*
