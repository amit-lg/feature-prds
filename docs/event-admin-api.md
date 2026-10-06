# Event Admin APIs

All routes are under the **command module**. Every request requires an employee JWT in the `Authorization: Bearer <token>` header.

**Base URL:** `{{baseUrl}}/api/command`

---

## Authentication

All endpoints are guarded by `EmployeeAuthGuard`. Include the employee token on every request:

```
Authorization: Bearer <employee_jwt>
```

---

## 1. Events (Core)

### List Events
```
GET /api/command/Event
```
**Query params (all optional):**
| Param | Type | Description |
|---|---|---|
| `startDate` | ISO date string | Filter events starting from this date |
| `endDate` | ISO date string | Filter events ending before this date |
| `courseId` | number | Filter by linked course |
| `platformId` | number | Filter by linked platform |
| `type` | string | Filter by event type |
| `eventName` | string | Filter by event title |

---

### Get Event by ID
```
GET /api/command/event/:eventId
```
Returns the event with its `Meta`, `Location`, and `CourseNdPlatform` relations included.

---

### Create Event
```
POST /api/command/event
Content-Type: multipart/form-data
```
**Body (form-data):**
| Field | Type | Required | Description |
|---|---|---|---|
| `file` | File | No | Event logo (JPEG/PNG only) |
| `title` | string | Yes | Event title |
| `description` | string | No | Short description |
| `startDate` | ISO date string | No | Event start date |
| `endDate` | ISO date string | No | Event end date |
| `color` | string | No | Hex or CSS color for UI display |
| `link` | string | No | External link / registration URL |
| `type` | string | No | Event type identifier |

---

### Update Event
```
PATCH /api/command/event/:eventId
Content-Type: multipart/form-data
```
Same fields as Create Event — all are optional. Send only the fields you want to update.

---

### Delete Event
```
DELETE /api/command/event/:eventId
```
Permanently deletes the event.

---

## 2. Event Meta

Extended description and date info for an event. Each event has at most one meta record (upsert behavior — both POST and PATCH create-or-update).

### Add / Upsert Meta
```
POST /api/command/event/:eventId/meta
Content-Type: application/json
```

### Update Meta
```
PATCH /api/command/event/:eventId/meta
Content-Type: application/json
```

**Body (same for both):**
```json
{
  "longDescription": "Full HTML or markdown description shown on the event detail page",
  "shortDescription": "One-liner shown in cards/listings",
  "startDate": "2026-06-01T10:00:00.000Z",
  "endDate": "2026-06-03T18:00:00.000Z"
}
```
All fields are optional.

---

## 3. Event Locations

An event can have multiple venue/location entries.

### Get Locations
```
GET /api/command/event/:eventId/location
```

### Add Location
```
POST /api/command/event/:eventId/location
Content-Type: application/json
```
**Body:**
```json
{
  "name": "Main Hall",
  "address": "123 MG Road",
  "city": "Bengaluru",
  "state": "Karnataka",
  "country": "India",
  "pincode": "560001",
  "mode": "offline",
  "addressLink": "https://maps.google.com/?q=..."
}
```
`name` is required. All other fields are optional.

`mode` values suggestion: `"online"` | `"offline"` | `"hybrid"` (free string, no enum enforced).

### Update Location
```
PATCH /api/command/event/:eventId/location/:locationId
Content-Type: application/json
```
Same body as Add Location — all fields optional.

### Delete Location
```
DELETE /api/command/event/:eventId/location/:locationId
```

---

## 4. Event Options

Flexible key-value metadata attached to an event (e.g. registration fee, capacity, tags).

### Get Options
```
GET /api/command/event/:eventId/option
```

### Add Option
```
POST /api/command/event/:eventId/option
Content-Type: application/json
```
**Body:**
```json
{
  "key": "maxAttendees",
  "type": "number",
  "valueText": "200",
  "valueJson": null
}
```
`key` is required. Use `valueText` for simple strings/numbers and `valueJson` for structured data.

### Update Option
```
PATCH /api/command/event/:eventId/option/:optionId
Content-Type: application/json
```
Same body as Add Option.

### Delete Option
```
DELETE /api/command/event/:eventId/option/:optionId
```

---

## 5. Event ↔ Course / Platform Links

Links an event to a platform and/or a specific course so it appears in the right tenant/course context.

### Get Links
```
GET /api/command/event/:eventId/course-platform
```
Returns each link with the related `Course` and `Platform` objects.

### Add Link
```
POST /api/command/event/:eventId/course-platform
Content-Type: application/json
```
**Body:**
```json
{
  "platformId": 3,
  "courseId": 12
}
```
Both fields are optional — send only `platformId` to link at platform level without a specific course, or send both.

### Remove Link
```
DELETE /api/command/event/:eventId/course-platform/:linkId
```
`linkId` is the `id` of the `EventsToCourseNdPlatform` record returned by the Get Links endpoint.

---

## 6. Event Attendees (Users)

Manage the list of people registered / attending an event.

### Get Attendees
```
GET /api/command/event/:eventId/user
```
Returns a paginated list of attendee records with the linked `User` profile (password omitted) and `location` object. Page size is fixed at **100**.

**Query params (all optional):**
| Param | Type | Description |
|---|---|---|
| `page` | number | Zero-based page index. Defaults to `0`. |

### Search Attendees
```
GET /api/command/event/:eventId/user/search
```
Full-text, `responseJson`-filtered, and enrollment-status search. Page size is fixed at **50**.

**Query params (all optional):**

| Param | Type | Description |
|---|---|---|
| `search` | string | Free-text match across `fname`, `lname`, `email`, `phone`. A space splits it into `fname + lname`. |
| `responseKey` | string | *(Legacy)* Key inside `responseJson` to match. Must be paired with `responseValue`. |
| `responseValue` | string | *(Legacy)* Value to match for `responseKey`. |
| `responseFilters` | JSON string | **Multi-key filter.** JSON-encoded array of `{key, values[]}` objects. Within one key values are **OR**; across keys they are **AND**. See examples below. |
| `enrollmentStatus` | string | Filter by user enrollment state. One of: `enrolled`, `not-enrolled`, `no-account`, `first-time`. See table below. |
| `enrolledCourseId` | number | Filter attendees enrolled in a specific course (by course id). Implies `enrolled`. |
| `page` | number | Zero-based page index. Defaults to `0`. |

**`enrollmentStatus` values:**

| Value | Returns attendees who… |
|---|---|
| `enrolled` | have a linked user account with at least one course enrollment |
| `not-enrolled` | have a linked user account but **no** course enrollments |
| `no-account` | have **no** linked user account (email/phone-only registrations) |
| `first-time` | have **never appeared in any other event AND have no lead record** (matched by userId, email, or phone across both `EventToUser` and `UserLead`) |

> `enrolledCourseId` takes precedence over `enrollmentStatus` when both are supplied.

**`responseFilters` — OR within a key, AND across keys:**

Single key, single value:
```
?responseFilters=[{"key":"dietaryPreference","values":["veg"]}]
```

Single key, **multiple values (OR)**:
```
?responseFilters=[{"key":"dietaryPreference","values":["veg","nonveg"]}]
```

Multiple keys (all must match — AND):
```
?responseFilters=[{"key":"dietaryPreference","values":["veg","nonveg"]},{"key":"city","values":["Mumbai","Delhi"]}]
```

> The legacy `{key, value}` shape (single string `value`) is still accepted for backward compatibility.

**Response shape:**
```json
{
  "data": [ /* EventToUser records with User (password omitted) and location included */ ],
  "total": 24,
  "page": 0,
  "limit": 50
}
```

> **Note:** The `/event/:eventId/user/count` endpoint returns the count of **all** attendees regardless of pagination and is unaffected by the `page` param.

### Add Attendee
```
POST /api/command/event/:eventId/user
Content-Type: application/json
```
**Body:**
```json
{
  "fname": "Priya",
  "lname": "Sharma",
  "email": "priya@example.com",
  "countryCode": "+91",
  "phone": "9876543210",
  "responseJson": { "dietaryPreference": "veg" },
  "locationId": 5,
  "userId": 101,
  "courseId": 12
}
```
All fields are optional. Use `userId` to link to an existing platform user; `locationId` links to one of the event's location records.

### Update Attendee
```
PATCH /api/command/event/:eventId/user/:eventUserId
Content-Type: application/json
```
Same body as Add Attendee — send only changed fields.

### Remove Attendee
```
DELETE /api/command/event/:eventId/user/:eventUserId
```
`eventUserId` is the `id` of the `EventToUser` record (not the platform `userId`).

---

## 7. Event Gallery

Link existing `Gallery` records to an event.

### Get Gallery
```
GET /api/command/event/:eventId/gallery
```
Returns gallery links with the full `Gallery` object.

### Add Gallery Item
```
POST /api/command/event/:eventId/gallery
Content-Type: application/json
```
**Body:**
```json
{
  "galleryId": 42,
  "featured": true
}
```
`galleryId` is required. `featured` (boolean) marks the item as the hero/featured image.

### Remove Gallery Item
```
DELETE /api/command/event/:eventId/gallery/:galleryId
```
`:galleryId` here is the `id` of the `EventToGallery` join record, **not** the `Gallery.id`.

---

## Quick Reference

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/command/Event` | List events (filterable) |
| GET | `/api/command/event/:id` | Get single event |
| POST | `/api/command/event` | Create event (multipart) |
| PATCH | `/api/command/event/:id` | Update event (multipart) |
| DELETE | `/api/command/event/:id` | Delete event |
| POST | `/api/command/event/:id/meta` | Upsert event meta |
| PATCH | `/api/command/event/:id/meta` | Upsert event meta |
| GET | `/api/command/event/:id/location` | List locations |
| POST | `/api/command/event/:id/location` | Add location |
| PATCH | `/api/command/event/:id/location/:lid` | Update location |
| DELETE | `/api/command/event/:id/location/:lid` | Delete location |
| GET | `/api/command/event/:id/option` | List options |
| POST | `/api/command/event/:id/option` | Add option |
| PATCH | `/api/command/event/:id/option/:oid` | Update option |
| DELETE | `/api/command/event/:id/option/:oid` | Delete option |
| GET | `/api/command/event/:id/course-platform` | List course/platform links |
| POST | `/api/command/event/:id/course-platform` | Add course/platform link |
| DELETE | `/api/command/event/:id/course-platform/:lid` | Remove link |
| GET | `/api/command/event/:id/user` | List attendees (100/page, zero-based `page` param) |
| GET | `/api/command/event/:id/user/count` | Total attendee count (unpaginated) |
| GET | `/api/command/event/:id/user/search` | Search attendees (text, responseFilters OR/AND, enrollmentStatus, enrolledCourseId) |
| GET | `/api/command/event/:id/user/breakdown-count` | Attendee breakdown (enrolled / account / lead / unique) |
| POST | `/api/command/event/:id/user` | Add attendee |
| PATCH | `/api/command/event/:id/user/:uid` | Update attendee |
| DELETE | `/api/command/event/:id/user/:uid` | Remove attendee |
| GET | `/api/command/event/:id/gallery` | List gallery items |
| POST | `/api/command/event/:id/gallery` | Add gallery item |
| DELETE | `/api/command/event/:id/gallery/:gid` | Remove gallery item |
