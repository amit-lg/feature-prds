# Airtel IVR — Inbound Call Routing

## Overview

When a customer dials the company's virtual number, Airtel calls our webhook. We look up which employee is assigned to that lead and tell Airtel which number to connect the call to. Airtel then patches both parties together.

No authentication guard is applied — this endpoint is not called by our users or employees. It is called by Airtel's platform directly, validated via a `dauth` header. We generate the token and share it with Airtel; they must include it in every request.

---

## Endpoint

```
POST /api/ivr/inbound
```

### Headers

| Header | Value |
|---|---|
| `dauth` | `<token we provide to Airtel>` |
| `Content-Type` | `application/json` |

The token is stored in env var `airtel_ivr_dauth`. Set it to any strong secret string and share it with Airtel.

---

### Request Body (sent by Airtel)

```json
{
  "callingParticipant": "9876543210",
  "callerId": "1111111111"
}
```

| Field | Type | Description |
|---|---|---|
| `callingParticipant` | string | The customer's phone number (who dialed in) |
| `callerId` | string | The virtual number the customer dialed (registered with Airtel) |

---

### Response (consumed by Airtel)

```json
{
  "client_add_participant": {
    "participants": [
      {
        "participantName": "Airtel_TEST",
        "participantAddress": "9999999999",
        "callerId": "1111111111",
        "maxRetries": 1,
        "audioId": 0,
        "maxTime": 0,
        "enableEarlyMedia": "false"
      }
    ],
    "mergingStrategy": "SEQUENTIAL",
    "maxTime": 0
  }
}
```

| Field | Description |
|---|---|
| `participantAddress` | The agent/employee's phone number — Airtel dials this and patches both parties |
| `callerId` | Passed back as-is from the request (the virtual number) |
| `participantName` | Fixed as `"Airtel_TEST"` per Airtel's spec |
| `maxRetries` | Airtel will retry this number once if there is no answer |
| `mergingStrategy` | `SEQUENTIAL` — Airtel connects to the single agent provided |

---

### Error Responses

| Status | Condition |
|---|---|
| `401 Unauthorized` | Missing or invalid `dauth` header |
| `400 Bad Request` | Lead not found AND no fallback number configured (`airtel_ivr_fallback` is empty) |

---

## Routing Logic

```
callingParticipant (customer number)
    ↓
Normalize phone (strip "91" prefix if 12-digit Indian number)
    ↓
Look up UserLead by phone OR whatsapp (tries both raw and normalized)
    ↓
Found?  ──Yes──→ LeadToEmployee → Employee → EmployeePersonal[0].phone
    ↓ No
Use airtel_ivr_fallback (env var — a default agent/front-desk number)
    ↓
No fallback configured?  ──→  400 Bad Request
    ↓
Return client_add_participant with the resolved number
```

The lookup matches against `UserLead.phone` and `UserLead.whatsapp`. Both the raw number and the 10-digit normalized version are tried in a single `OR` query so numbers stored either way are matched.

---

## Environment Variables

| Variable | Description | Example |
|---|---|---|
| `airtel_ivr_dauth` | Secret token we give to Airtel; they must send it in the `dauth` header | `some-strong-secret` |
| `airtel_ivr_fallback` | Default agent number when caller is not a known lead | `9800000000` |

**Set `airtel_ivr_fallback` to a real number** (e.g. front desk or a general agent). If left blank and the caller is not a known lead, the call will fail with a 400.

---

## Where Code Lives

| What | File |
|---|---|
| Controller | `src/ivr/ivr.controller.ts` |
| Service | `src/ivr/ivr.service.ts` |
| Module | `src/ivr/ivr.module.ts` |

No middleware is applied to this module — `PlatformCheckMiddleware` is intentionally absent since Airtel does not send `origin` or `dauth` headers.

---

## Setup Checklist

1. Set `airtel_ivr_dauth` in `.env` to a strong secret string
2. Set `airtel_ivr_fallback` to a real phone number in `.env`
3. Share `airtel_ivr_dauth` value and endpoint URL (`https://growthcommand.aswinibajaj.com/api/ivr/inbound`) with Airtel so they configure the `getClientData` component
4. Ensure each lead in the system has an assigned employee (`LeadToEmployee` record) with a phone number in `EmployeePersonal.phone` — otherwise all calls fall back to the fallback number
