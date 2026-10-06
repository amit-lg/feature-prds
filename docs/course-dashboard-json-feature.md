# Course Dashboard JSON (CourseOption)

## Overview

A per-course "dashboard" content block — a title, description, and up to five media items (image/video/audio) — configurable per course for display on a course dashboard/home screen. It is not a new table: it is stored using the existing generic key/value store, [`CourseOption`](../prisma/schema.prisma), under a dedicated key.

No new Prisma model or migration is required.

---

## Storage

Uses the existing `CourseOption` model:

```prisma
model CourseOption {
  id        Int     @id @default(autoincrement())
  key       String
  valueJson Json?
  courseId  Int
  type      String?
  valueText String?
  Course    Course  @relation(fields: [courseId], references: [id])
}
```

| Field | Value for this feature |
|---|---|
| `key` | `"dashboardJson"` (literal, exact match) |
| `type` | `"JSON"` |
| `courseId` | The course this dashboard content belongs to |
| `valueJson` | The dashboard payload (see shape below) — `title`, `description`, `media[]` |
| `valueText` | Not used (`null`) |

One row per course. A course with no `dashboardJson` row simply has no dashboard content configured — the frontend should treat this as "feature disabled" for that course, the same way `StudyPlan` and other feature-flag keys are handled (see [lecture-plan-feature.md](./lecture-plan-feature.md#pre-conditions)).

---

## `valueJson` shape

A course dashboard is made up of multiple **boxes** — `valueJson` is an **array**, not a single object. Each element is one box with its own `title`, `description`, and up to five media items.

```json
[
  {
    "title": "Welcome to JEE Crash Course",
    "description": "Everything you need to know before you start.",
    "media": [
      { "type": "image", "url": "https://cdn.example.com/banner.jpg", "caption": "Course banner" },
      { "type": "video", "url": "https://cdn.example.com/intro.mp4", "caption": "Intro walkthrough" },
      { "type": "audio", "url": "https://cdn.example.com/welcome.mp3", "caption": "Audio welcome note" }
    ]
  },
  {
    "title": "Meet Your Faculty",
    "description": "The instructors teaching this course.",
    "media": [
      { "type": "image", "url": "https://cdn.example.com/faculty.jpg", "caption": "Faculty lineup" }
    ]
  }
]
```

| Field | Type | Notes |
|---|---|---|
| `valueJson` (root) | Array | One entry per dashboard box, ordered — render in array order |
| `[].title` | String | Box heading |
| `[].description` | String | Body text shown under the title |
| `[].media` | Array (0–5 items) | Ordered — render in array order |
| `[].media[].type` | String | One of `"image"`, `"video"`, `"audio"` |
| `[].media[].url` | String | Link to the asset (Vultr/S3-hosted, same as other course media) |
| `[].media[].caption` | String? | Optional per-item label/caption |

**Validation rules:**
- Root: array (no cap on number of boxes unless product requires one — flagged as an open item below)
- Each box's `title`: required, non-empty string
- Each box's `description`: required, non-empty string
- Each box's `media`: array, max length **5**; each entry requires `type` (enum: `image`/`video`/`audio`) and `url`; `caption` optional

---

## API Endpoints

Dedicated endpoints exist for this key in [`command.controller.ts`](../src/command/command.controller.ts) / [`platform.service.ts`](../src/platform/platform.service.ts) — they replace the need to go through the generic `add-course-option` / `course-option` endpoints for this feature. Both require `EmployeeAuthGuard` (employee JWT, `path: 'command'`).

### `GET /command/course-option/:courseId/dashboard-json`

Returns the current dashboard boxes for a course. Requires the `canViewCourse` permission.

**Response:** the raw `valueJson` array — `[]` if the course has no `dashboardJson` `CourseOption` row yet.

```json
[
  {
    "title": "Welcome to JEE Crash Course",
    "description": "Everything you need to know before you start.",
    "media": [
      { "type": "image", "url": "https://cdn.example.com/banner.jpg", "caption": "Course banner" }
    ]
  }
]
```

Throws `404 Not Found` if `courseId` doesn't exist.

### `PUT /command/course-option/:courseId/dashboard-json`

Creates the `dashboardJson` `CourseOption` row for the course if it doesn't exist, or **replaces the entire array** if it does (upsert, whole-document replace — not a per-box patch). Requires the `canCreateCourse` permission.

**Body** (`UpsertDashboardJsonDto`):
```json
{
  "boxes": [
    {
      "title": "Welcome to JEE Crash Course",
      "description": "Everything you need to know before you start.",
      "media": [
        { "type": "image", "url": "https://cdn.example.com/banner.jpg", "caption": "Course banner" },
        { "type": "video", "url": "https://cdn.example.com/intro.mp4", "caption": "Intro walkthrough" }
      ]
    },
    {
      "title": "Meet Your Faculty",
      "description": "The instructors teaching this course.",
      "media": []
    }
  ]
}
```

**Validation (enforced server-side via `class-validator`):**
- `boxes`: required array
- Each box: `title` and `description` required, non-empty strings
- Each box's `media`: optional array, **max 5 items**; each item requires `type` (`image` | `video` | `audio`) and `url`; `caption` optional

Throws `404 Not Found` if `courseId` doesn't exist, `403 Forbidden` if the employee lacks `canCreateCourse`, `400 Bad Request` on validation failure (e.g. a 6th media item, missing `title`).

**Response:** the updated `CourseOption` row (`{ id, key, valueJson, courseId, type, valueText }`).

To send/remove a specific box, the frontend must send the **full** updated `boxes` array (add/edit/remove client-side, then `PUT` the whole thing) — there is no per-box add/delete endpoint.

---

## Reading and writing via the generic endpoints (still works)

Since `dashboardJson` is just a `CourseOption` key, it also remains readable/writable through the generic endpoints — useful for bulk imports or when other options are being set in the same call:

- `PATCH /command/course-option/:courseId` (`AddCourseOptionDto`, `options: { dashboardJson: [...] }`) — same upsert-by-key logic as any other option.
- `GET /command/course-options` — returns distinct `{ key, type }` pairs across all courses (discovery only, not a per-course value fetch).
- `POST /command/add-course-option` (`AddNewCourseOptionDto`) — creates the key row for the *first* course only; `PlatformService.addNewCourseOption`'s uniqueness check is global by `key`, not `(key, courseId)`, so it 400s for every course after the first. Prefer the dedicated `PUT` endpoint above, which does not have this limitation (it scopes its existence check to `courseId + key`).

---

## Frontend Instructions

### Admin / Command panel (content managers)

**1. Loading the dashboard editor for a course**

```
GET /command/course-option/:courseId/dashboard-json
```
Renders a list of box editor cards, one per array entry. Empty array (`[]`) → show a "No dashboard boxes yet" empty state with an "Add box" button rather than an error.

**2. Editing boxes**

All box add/edit/remove/reorder happens client-side against the in-memory array — there is no per-box API. Give each box:
- Title input (required)
- Description textarea (required)
- Media list (up to 5): a type selector (`image`/`video`/`audio`), a URL/upload field, and an optional caption input. Disable "Add media" once the box has 5 items.
- Drag-to-reorder for both boxes and the media list within a box — array order is render order on the student side.

**3. Saving**

```
PUT /command/course-option/:courseId/dashboard-json
```
Send the entire current `boxes` array on every save — this is a full replace, not a diff/patch. Debounce or use an explicit "Save" button rather than autosaving on every keystroke, since each save is a full-document write.

Handle `400` responses by surfacing the validation message inline (e.g. missing title on a box, more than 5 media items) rather than a generic toast, since the message identifies which rule failed.

**4. Suggested flow**

```
Course settings → "Dashboard" tab
    ↓
GET /course-option/:courseId/dashboard-json  → populate box list (or empty state)
    ↓
Employee adds/edits/removes/reorders boxes and their media (client-side only)
    ↓
"Save" → PUT /course-option/:courseId/dashboard-json with full boxes[] array
    ↓
On success, replace local state with the response's valueJson to confirm persisted order
```

### Student-facing app (rendering the dashboard)

No student-facing read endpoint exists yet for this key specifically — it is currently only exposed through the command/admin API above. If a student-facing screen needs to render these boxes (e.g. a course home/dashboard section), a public read endpoint scoped to the student's enrolled course should be added (mirroring how `checkStudyPlan` reads `CourseOption` in [lecture-plan-feature.md](./lecture-plan-feature.md#pre-conditions)) before any frontend work on that side begins. Until then, do not build against `GET /command/course-option/:courseId/dashboard-json` from the student app — it is gated behind `EmployeeAuthGuard` and will reject a user JWT.

**When that endpoint exists**, the rendering contract is:
- Render `boxes` in array order, top to bottom (or as horizontally-scrollable cards — designer's call).
- Within each box, render `media` in array order.
- `type: "image"` → `<img>`/`Image` component; `type: "video"` → inline player or thumbnail-to-modal; `type: "audio"` → an audio player control. Use `caption` as alt text / a small label under the media, when present.
- A box with `media: []` is valid — render title/description only, no media row.
- If the course has no `dashboardJson` configured, hide the dashboard section entirely rather than showing an empty block.

---

## Open items / suggested follow-ups

- No student-facing (`AuthGuard`) read endpoint exists yet — only the employee-facing pair above. Add one scoped to the student's own enrolled/watching course before building the student-side UI (see Frontend Instructions above).
- Confirm with product whether the number of boxes per dashboard should be capped (e.g. max 5 or 10 boxes) — currently unbounded; only the per-box `media` array is capped at 5.
- The `PUT` endpoint is a full-array replace. If concurrent editors become a concern (two admins editing the same course's dashboard at once), consider optimistic concurrency (e.g. an `updatedAt`/version check) rather than last-write-wins.
