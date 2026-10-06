# Lecture & Video Admin API

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

Every request must include the employee token in the header:

```
Authorization: Bearer <employee_token>
```

---

## Base URL

```
/api/command
```

---

## Lectures

### List lectures

```
GET /api/command/lectureInfo
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `lectureName` | string | Filter by lecture name (partial match) |
| `lectureId` | integer | Filter by specific lecture ID |
| `courseId` | integer | Filter lectures linked to this course |
| `fallId` | integer | Filter lectures linked to this fall number |
| `videoId` | integer | Filter lectures containing this video |
| `startDate` | date string | Lower bound on lecture date |
| `endDate` | date string | Upper bound on lecture date |
| `page` | integer | Page number for pagination |
| `sortBy` | string | `date-asc` \| `date-desc` |

**Response** — array of lecture records with linked videos and course assignments.

---

### Create lecture

```
POST /api/command/lectureInfo
```

**Body** (`application/json`)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `lectureName` | string | yes | Display name of the lecture |
| `remarks` | string | no | Internal notes or remarks |
| `contentCovered` | string | no | Summary of topics covered |
| `reference` | string | no | Reference materials or links |

---

### Edit lecture

```
PATCH /api/command/lectureInfo/:lectureId
```

**Path param**: `lectureId` — integer ID of the lecture to update.

**Body** (`application/json`) — all fields optional

| Field | Type | Description |
|-------|------|-------------|
| `lectureName` | string | New display name |
| `remarks` | string | Updated remarks |
| `contentCovered` | string | Updated content summary |
| `reference` | string | Updated references |

---

### Rearrange lectures within a course

```
PATCH /api/command/rearrange-lecture
```

Reorders all lectures for a course by reassigning `order` values (1-indexed) based on the sequence of IDs sent.

**Body** (`application/json`)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `courseId` | integer | yes | The course whose lecture order is being changed |
| `lectureIds` | integer[] | yes | All lecture IDs in the desired order |

**Response**

```json
{ "message": "Lectures rearranged successfully" }
```

---

### Link / unlink lecture to course

```
GET /api/command/add-lecture-info-course?lectureId=<int>&courseId=<int>
```

Toggles the association between a lecture and a course:
- If the link does not exist, it is created and the lecture is appended at the end of the course order.
- If the link already exists, it is deleted and remaining lectures are re-ordered automatically.

**Query params**

| Param | Type | Required |
|-------|------|----------|
| `lectureId` | integer | yes |
| `courseId` | integer | yes |

---

### Edit lecture-to-course order fields *(new)*

```
PATCH /api/command/lectureToCourse/:id
```

Updates the `order` (numeric position) and/or `orderName` (display label) on an existing `LectureToCourse` record.

**Path param**: `id` — integer ID of the `LectureToCourse` record (not the lecture ID).

**Body** (`application/json`) — at least one field required

| Field | Type | Description |
|-------|------|-------------|
| `order` | integer | Numeric sort order within the course |
| `orderName` | string | Human-readable label, e.g. `"Week 3"` |

**Example**

```json
{
  "order": 3,
  "orderName": "Week 3"
}
```

**Response** — the updated `LectureToCourse` record.

```json
{
  "id": 42,
  "lectureId": 7,
  "courseId": 2,
  "order": 3,
  "orderName": "Week 3"
}
```

---

## Videos

### List video info

```
GET /api/command/videoInfo
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `videoCode` | string | Exact code to look up |
| `videoId` | integer | Filter by video ID |
| `lectureId` | integer | Filter videos linked to this lecture |
| `fallId` | integer | Filter videos linked to this fall number |
| `courseId` | integer | Filter videos whose lectures belong to this course |
| `startDate` | date string | Lower bound on video date |
| `endDate` | date string | Upper bound on video date |
| `page` | integer | Page number for pagination |
| `sortBy` | string | `date-asc` \| `date-desc` |

---

### Create video info

```
POST /api/command/videoInfo
```

**Body** (`application/json`)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `videoCode` | string | yes | Unique video identifier code |
| `duration` | integer | no | Duration in seconds |
| `videoType` | string | yes | `live` \| `recorded` |
| `tab` | string | no | Tab/section label (e.g. `"Exam Mentoring"`) |
| `startDate` | date string | no | Scheduled start datetime |
| `endDate` | date string | no | Scheduled end datetime |

---

### Edit video info *(includes new `importance` field)*

```
PATCH /api/command/videoInfo/:videoId
```

**Path param**: `videoId` — integer ID of the video to update.

**Body** (`application/json`) — all fields optional

| Field | Type | Description |
|-------|------|-------------|
| `videoCode` | string | Updated video code |
| `duration` | integer | Duration in seconds |
| `videoType` | string | `live` \| `recorded` |
| `tab` | string | Tab/section label |
| `startDate` | date string | Scheduled start datetime |
| `endDate` | date string | Scheduled end datetime |
| `importance` | string | `required` \| `optional` \| `recommended` |

**Example — setting importance**

```json
{
  "importance": "required"
}
```

**Response** — the updated `VideoInfo` record.

---

### Link / unlink video to lecture

```
GET /api/command/connect-video-info-lecture?videoId=<int>&lectureId=<int>
```

Toggles the link between a video and a lecture. If the link exists it is removed; otherwise it is created.

**Query params**

| Param | Type | Required |
|-------|------|----------|
| `videoId` | integer | yes |
| `lectureId` | integer | yes |

---

### Link video to fall number

```
GET /api/command/connect-video-info-fallnumber?videoId=<int>&fallnumber=<int>
```

Toggles the association between a video and a fall number.

**Query params**

| Param | Type | Required |
|-------|------|----------|
| `videoId` | integer | yes |
| `fallnumber` | integer | yes |

---

## Video Vault (PDF attachments)

### Upload PDF to video

```
POST /api/command/videoVault/:videoId
```

**Path param**: `videoId` — string (cast to integer server-side).

**Body** — `multipart/form-data`. Attach files under the field name `uploadedFiles`. Only `application/pdf` is accepted; other MIME types return `403 Forbidden`.

---

### Delete PDF from video

```
DELETE /api/command/videoVault/:vaultId
```

**Path param**: `vaultId` — integer ID of the vault record to delete.

---

## Solution Video Info

### Add solution text

```
POST /api/command/solution-video-info/:videoId
```

**Path param**: `videoId` — integer.

**Body** (`application/json`)

| Field | Type | Required |
|-------|------|----------|
| `solutionText` | string | yes |

---

### Update solution text

```
PATCH /api/command/solution-video-info/:solutionId
```

**Path param**: `solutionId` — integer.

**Body** (`application/json`)

| Field | Type | Required |
|-------|------|----------|
| `solutionText` | string | yes |

---

### Delete solution text

```
DELETE /api/command/solution-video-info/:solutionId
```

**Path param**: `solutionId` — integer.

---

### Add solution texts in batch

```
POST /api/command/solution-video-info-in-batch
```

**Body** — array of `SolutionVideoInfoInBatchDto` objects. Each item specifies a `videoId` and `solutionText`.

---

## Error responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Missing required param or record not found |
| `401 Unauthorized` | Missing or invalid employee JWT |
| `403 Forbidden` | Invalid file type (vault upload) |
