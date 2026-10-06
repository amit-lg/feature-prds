# Formula Admin API

All routes are under the **Command** module and require an **employee JWT token**.

---

## Authentication

Every request must include the employee token in the header:

```
Authorization: Bearer <employee_token>
```

**Required permissions** (checked server-side against the employee's permission tree):

| Action | Permission |
|--------|------------|
| View formulas | `canViewFormula` |
| Create formulas | `canCreateFormula` |
| Edit formulas / explanations / fall numbers | `canEditFormula` |
| Delete formulas | `canDeleteFormula` |

If the employee does not have the required permission the server responds with `403 Forbidden`.

---

## Attachments

The following endpoints accept file uploads directly — **no separate upload step needed**:

- Create formula
- Update formula

### How to send files

Use `multipart/form-data`. Send all text fields as form fields and attach files under the field name **`files`**.

```
Content-Type: multipart/form-data

question=Force = mass × acceleration
answer=F = ma
difficulty=3
files=<binary: diagram.png>
```

Up to **5 files** per request. **5 MB max** per file. Supported types: images, audio, video.

The server uploads each file to Vultr object storage and stores the resulting `[{ link, type }]` array in the `attachment` field:

```json
"attachment": [
  { "link": "https://cdn.example.com/formula/uuid-diagram.png", "type": "image/png" }
]
```

### Behaviour on update

If you send files on an update (`PATCH`), the `attachment` field is **replaced** with the newly uploaded files merged with any remaining existing ones. Use `imagesToRemove` to drop specific links from the existing set. If you send no files and no `imagesToRemove`, `attachment` is left unchanged.

### Endpoints without file uploads

Explanation and fall-number endpoints use regular `application/json`.

---

## Base URL

```
/api/command
```

---

## Formulas

### List formulas

```
GET /api/command/formula
```

**Query params** — all optional, combinable

| Param | Type | Description |
|-------|------|-------------|
| `fallNumberId` | integer | Filter formulas tagged with this fall number |
| `courseId` | integer | Filter formulas whose fall numbers are mapped to this course |
| `search` | string | Case-sensitive search within question text and answer text |
| `formulaCode` | string | Case-insensitive contains search on the `formulaCode` field |
| `page` | integer | Page number (0-indexed). Returns 10 results per page. Defaults to `0`. |

Results are ordered by `id ASC`.

**Response**

Each item includes:
- All formula fields including `createdAt`, `updatedAt`
- `Explaination[]` — linked explanations (via join table), each with the full `FormulaExplaination` record
- `FallNumber[]` — fall number tags with their linked courses

```json
[
  {
    "id": 1,
    "question": "Force = mass × acceleration",
    "answer": "F = ma",
    "attachment": [
      { "link": "https://cdn.example.com/formula/uuid-diagram.png", "type": "image/png" }
    ],
    "difficulty": 3,
    "formulaCode": "PHY-001",
    "createdAt": "2025-05-01T10:00:00.000Z",
    "updatedAt": "2025-05-20T10:00:00.000Z",
    "Explaination": [
      {
        "id": 1,
        "explainationId": 4,
        "formulaId": 1,
        "Explaination": {
          "id": 4,
          "explainationText": "Newton's second law of motion states that force equals mass times acceleration.",
          "footnote": "Applies to constant mass systems only."
        }
      }
    ],
    "FallNumber": [
      {
        "formulaId": 1,
        "fallId": 7,
        "FallNumber": {
          "id": 7,
          "number": "PHY-101",
          "Course": [
            {
              "id": 12,
              "fallId": 7,
              "courseId": 3,
              "Course": { "id": 3, "name": "Physics Foundation" }
            }
          ]
        }
      }
    ]
  }
]
```

---

### Get single formula detail

```
GET /api/command/formula/:id
```

Returns the same shape as a single item from the list.

**Errors:**
- `404` if the formula does not exist.

---

### Create a formula

```
POST /api/command/formula
Content-Type: multipart/form-data
```

Send all fields as form fields. Optionally attach up to 5 files under the field name `files`.

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `question` | string | **Yes** | Formula question / name (HTML allowed) |
| `answer` | string | **Yes** | Formula expression or answer (HTML allowed) |
| `difficulty` | integer | No | Difficulty level 1–10 |
| `formulaCode` | string | No | Internal reference code e.g. `"PHY-001"` |
| `files` | file[] | No | Up to 5 files, max 5 MB each. Images / audio / video. |

**Example (curl)**

```bash
curl -X POST /api/command/formula \
  -H "Authorization: Bearer <token>" \
  -F "question=Force = mass × acceleration" \
  -F "answer=F = ma" \
  -F "difficulty=3" \
  -F "formulaCode=PHY-001" \
  -F "files=@diagram.png"
```

**Response** — the created formula object.

**Errors:**
- `409 Conflict` if a formula with the same `formulaCode` already exists.

---

### Update a formula

Only the fields you send are updated.

```
PATCH /api/command/formula/:id
Content-Type: multipart/form-data
```

**Fields**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `question` | string | No | Updated question text |
| `answer` | string | No | Updated answer text |
| `difficulty` | integer | No | Updated difficulty level |
| `formulaCode` | string | No | Updated reference code |
| `files` | file[] | No | New files to add. Merged with existing attachment after applying `imagesToRemove`. |
| `imagesToRemove` | string[] | No | Array of existing attachment `link` URLs to remove from the stored set. |

**Errors:**
- `404` if the formula does not exist.

---

### Delete a formula

```
DELETE /api/command/formula/:id
```

**Response**

```json
{ "message": "Formula deleted." }
```

**Errors:**
- `404` if the formula does not exist.

---

## Explanations

A formula can have one or more explanations linked via a join table. The set/upsert endpoint manages the **first** (or only) linked explanation. If you need multiple explanations per formula (e.g. per-course variants), link them separately via the database or extend this endpoint.

### Set or update formula explanation

Single endpoint — **creates the explanation if none exists, updates it if one already exists**.

```
PUT /api/command/formula/:id/explanation
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `explainationText` | string | **Yes** | Full explanation body (HTML allowed) |
| `footnote` | string | No | Short footnote or caveat. Defaults to `""`. |

**Example**

```json
{
  "explainationText": "Newton's second law: net force equals mass times acceleration. Valid for inertial frames.",
  "footnote": "Applies to constant mass systems only."
}
```

**Response** — the `FormulaExplaination` record (created or updated).

**Errors:**
- `404` if the formula does not exist.

---

## Fall Numbers (Subject Tags)

A fall number tags a formula with a subject, which is also mapped to one or more courses via `FallNumberToCourse`. This drives filtering by `courseId` in the list endpoint.

### Toggle fall number

Single endpoint — **adds the link if it doesn't exist, removes it if it does**.

```
POST /api/command/formula/:id/fall-number
Content-Type: application/json
```

**Body**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `fallNumberId` | integer | **Yes** | Fall number id to toggle |

**Response**

```json
{ "action": "added", "formulaId": 1, "fallNumberId": 7 }
```

or

```json
{ "action": "removed", "formulaId": 1, "fallNumberId": 7 }
```

Use `action` to update your UI state without a refetch.

**Errors:**
- `404` if the formula does not exist.

---

## Common Error Responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | Validation failed or missing required field |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Employee does not have the required permission |
| `404 Not Found` | The requested resource does not exist |
| `409 Conflict` | Creating a formula with a `formulaCode` that is already in use |

---

## Typical Flows

### Create a formula end-to-end

```
1. POST  /api/command/formula           (multipart)   → get formulaId
2. PUT   /api/command/formula/:id/explanation          → add explanation text
3. POST  /api/command/formula/:id/fall-number          → tag with subject/fall number
```

### Update only the answer text

```
PATCH /api/command/formula/:id
Content-Type: multipart/form-data

answer=F = m × a (updated wording)
```

### Swap an attachment image

```
PATCH /api/command/formula/:id
Content-Type: multipart/form-data

imagesToRemove=https://cdn.example.com/formula/old-uuid-diagram.png
files=@new-diagram.png
```

### Filter formulas for a specific course

```
GET /api/command/formula?courseId=3
```

Returns only formulas whose fall numbers are mapped to course id 3.

### Filter formulas for a specific fall number

```
GET /api/command/formula?fallNumberId=7
```

### Search by formula code

```
GET /api/command/formula?formulaCode=PHY
```

Returns all formulas whose `formulaCode` contains `PHY` (case-insensitive), e.g. `PHY-001`, `phy-042`.

### Paginate through all formulas

```
GET /api/command/formula?page=0   → first 10
GET /api/command/formula?page=1   → next 10
GET /api/command/formula?page=2   → next 10
```

Params can be combined: `?formulaCode=PHY&fallNumberId=7&page=1`

---

## Source Files

| File | Purpose |
|------|---------|
| `src/command/command.controller.ts` | Route definitions for all formula admin endpoints |
| `src/formula/formula.service.ts` | Admin business logic, permission checks, and DB queries |
| `src/formula/dto/admin/admin-get-formulas.dto.ts` | List query params |
| `src/formula/dto/admin/admin-create-formula.dto.ts` | Create payload |
| `src/formula/dto/admin/admin-update-formula.dto.ts` | Update payload |
| `src/formula/dto/admin/admin-set-formula-explanation.dto.ts` | Explanation upsert payload |
| `src/formula/dto/admin/admin-toggle-formula-fall-number.dto.ts` | Fall number toggle payload |
| `prisma/schema.prisma` lines 1184–1266 | DB schema for all Formula models |
| `src/common/utils/check-permission.ts` | Recursive permission resolver |
