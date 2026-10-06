# FAQ Admin API — Developer Reference

This document covers the full FAQ management system exposed through the Command controller. It is intended for backend developers and admin-panel engineers working with the Growth Command platform.

---

## Table of Contents

1. [Overview](#overview)
2. [Data Model](#data-model)
3. [Permissions](#permissions)
4. [Authentication](#authentication)
5. [API Endpoints](#api-endpoints)
   - [Subjects](#subjects)
   - [Questions](#questions)
   - [Content](#content)
   - [Mappings](#mappings)
   - [File Upload](#file-upload)
6. [Business Rules & Constraints](#business-rules--constraints)
7. [Content Types Reference](#content-types-reference)
8. [Ordering Logic](#ordering-logic)
9. [Error Reference](#error-reference)
10. [Source Files](#source-files)

---

## Overview

The FAQ system lets admins build a hierarchical knowledge base that can be scoped to a course, a platform, or globally. The hierarchy is:

```
FaqSubject (tree, unlimited depth)
  ├── FaqSubject (child subjects — recursive)
  ├── FaqQuestion[] (Q&A pairs, ordered)
  └── FaqContent[]  (rich media — video, PDF, doc, etc., ordered)

FaqToCourseNdPlatform  (mapping: subject ↔ course/platform)
```

All endpoints live under the global route prefix `/api` and are grouped under the `/command` controller, so the full base path is:

```
/api/faq/...
```

Every endpoint requires an authenticated **employee** (admin) JWT — user tokens are rejected.

---

## Data Model

### FaqSubject

| Column        | Type    | Required | Description                                            |
|---------------|---------|----------|--------------------------------------------------------|
| `id`          | Int     | auto     | Primary key                                            |
| `heading`     | String  | no       | Display title of the subject                           |
| `description` | String  | no       | Short description shown below the heading              |
| `logo`        | String  | no       | URL to a logo/icon image for the subject               |
| `faqSubjectId`| Int     | no       | Parent subject ID. `null` means this is a root subject |
| `order`       | Int     | no       | Sort position within siblings (nulls sort last)        |

A subject may have any number of child subjects, questions, and content items. Deleting a subject requires all of these to be removed first.

### FaqQuestion

| Column     | Type   | Required | Description                         |
|------------|--------|----------|-------------------------------------|
| `id`       | Int    | auto     | Primary key                         |
| `question` | String | yes      | The question text                   |
| `answer`   | String | yes      | The answer text (plain or rich text)|
| `subjectId`| Int    | yes      | FK → FaqSubject                     |
| `order`    | Int    | no       | Sort position within the subject    |

### FaqContent

| Column               | Type   | Required | Description                                              |
|----------------------|--------|----------|----------------------------------------------------------|
| `id`                 | Int    | auto     | Primary key                                              |
| `name`               | String | yes      | Display name of the content item                         |
| `description`        | String | no       | Optional caption or summary                              |
| `type`               | String | yes      | One of the seven content types (see below)               |
| `link`               | String | no       | Public URL (file, PDF, image, YouTube URL, etc.)         |
| `videoLink`          | String | no       | Public video URL (Vimeo, direct MP4, etc.)               |
| `protectedLink`      | String | no       | Signed/private URL for `link`                            |
| `protectedVideoLink` | String | no       | Signed/private URL for `videoLink`                       |
| `thumbnail`          | String | no       | Thumbnail image URL                                      |
| `subjectId`          | Int    | yes      | FK → FaqSubject                                          |

`FaqContent` does **not** have an `order` column in the database. The sort is performed in-memory using the `id` as a stable tiebreaker (see [Ordering Logic](#ordering-logic)).

### FaqToCourseNdPlatform (Mapping)

| Column        | Type | Required | Description                          |
|---------------|------|----------|--------------------------------------|
| `id`          | Int  | auto     | Primary key                          |
| `faqSubjectId`| Int  | yes      | FK → FaqSubject (root or child)      |
| `courseId`    | Int  | no       | FK → Course. `null` = all courses    |
| `platformId`  | Int  | no       | FK → Platform. `null` = all platforms|

The combination `(faqSubjectId, courseId, platformId)` is unique — creating a duplicate mapping returns `409 Conflict`.

---

## Permissions

All service methods check the calling employee's permission via `checkPermission()`. The four permission strings used are:

| Permission Key  | Grants access to                                              |
|-----------------|---------------------------------------------------------------|
| `canViewFaq`    | GET subject tree, GET questions, GET content                  |
| `canCreateFaq`  | POST subject, question, content, mapping; both upload routes  |
| `canEditFaq`    | PATCH subject, question, content                              |
| `canDeleteFaq`  | DELETE subject, question, content, mapping                    |

These keys are resolved through the recursive employee permission/group tree in `src/common/utils/check-permission.ts`. An employee without the relevant key receives `403 Forbidden`.

---

## Authentication

All FAQ endpoints use `@UseGuards(EmployeeAuthGuard)`. The guard expects:

```
Authorization: Bearer <employee-jwt>
```

The JWT must encode `path: 'command'` and a `platformId` that matches the request's `origin` or `dauth` header. Requests without a resolvable platform are rejected before the guard runs (`PlatformCheckMiddleware`).

---

## API Endpoints

### Subjects

#### GET `/api/faq/subject/tree`

Returns the full subject hierarchy as a nested tree.

**Permission:** `canViewFaq`

**Response:**

```json
[
  {
    "id": 1,
    "heading": "Getting Started",
    "description": "Onboarding topics",
    "logo": "https://cdn.example.com/logo.png",
    "order": 1,
    "children": [
      {
        "id": 3,
        "heading": "Account Setup",
        "description": null,
        "logo": null,
        "order": null,
        "children": []
      }
    ]
  }
]
```

- Root subjects (`faqSubjectId = null`) form the top-level array.
- Each node's `children` array is recursively built in memory (single DB query, O(n) tree build).
- Siblings are sorted by `order ASC NULLS LAST`, then `id ASC`.

---

#### POST `/api/faq/subject`

Creates a new FAQ subject.

**Permission:** `canCreateFaq`

**Request body:**

```json
{
  "heading": "Billing",
  "description": "Payment and invoice questions",
  "logo": "https://cdn.example.com/billing.png",
  "faqSubjectId": 1,
  "order": 2
}
```

| Field          | Type   | Required | Notes                                           |
|----------------|--------|----------|-------------------------------------------------|
| `heading`      | string | yes      |                                                 |
| `description`  | string | no       |                                                 |
| `logo`         | string | no       | URL to an image                                 |
| `faqSubjectId` | number | no       | ID of parent subject. Omit or `null` for root   |
| `order`        | number | no       | Sort order within siblings                      |

**Errors:**
- `404` if `faqSubjectId` references a non-existent subject.

---

#### PATCH `/api/faq/subject/:id`

Updates an existing subject. All fields are optional; only provided fields are written.

**Permission:** `canEditFaq`

**Path param:** `id` — integer subject ID.

**Request body:** Same shape as create, all fields optional.

**Guard rails enforced by the service:**
- `404` if subject `id` does not exist.
- `400` if `faqSubjectId === id` (a subject cannot be its own parent).
- `404` if the new `faqSubjectId` does not exist.
- `400` if the new `faqSubjectId` is a descendant of `id` (cycle prevention — the service walks the full ancestor chain).

---

#### DELETE `/api/faq/subject/:id`

Deletes a subject. The subject **must be empty** before deletion.

**Permission:** `canDeleteFaq`

**Path param:** `id` — integer subject ID.

**Pre-delete checks (all run in parallel):**

| Condition                                           | Error         |
|-----------------------------------------------------|---------------|
| Subject has child subjects                          | `409 Conflict` |
| Subject has one or more questions or content items  | `409 Conflict` |
| Subject has active course/platform mappings         | `409 Conflict` |

**Success response:**

```json
{ "message": "FAQ subject deleted successfully." }
```

---

### Questions

#### GET `/api/faq/question?subjectId=<id>`

Returns all questions for a given subject, sorted by `order ASC NULLS LAST`, then `id ASC`.

**Permission:** `canViewFaq`

**Query param:** `subjectId` (integer, required)

**Response:**

```json
[
  {
    "id": 10,
    "question": "How do I reset my password?",
    "answer": "Click Forgot Password on the login screen.",
    "subjectId": 3,
    "order": 1
  }
]
```

**Errors:**
- `404` if `subjectId` does not exist.

---

#### POST `/api/faq/question`

Creates a new Q&A pair under a subject.

**Permission:** `canCreateFaq`

**Request body:**

```json
{
  "question": "How do I reset my password?",
  "answer": "Click Forgot Password on the login screen.",
  "subjectId": 3,
  "order": 1
}
```

| Field      | Type   | Required | Notes                            |
|------------|--------|----------|----------------------------------|
| `question` | string | yes      |                                  |
| `answer`   | string | yes      |                                  |
| `subjectId`| number | yes      | Must reference an existing subject |
| `order`    | number | no       | Sort position                    |

**Errors:**
- `404` if `subjectId` does not exist.

---

#### PATCH `/api/faq/question/:id`

Updates a question. All fields are optional.

**Permission:** `canEditFaq`

**Path param:** `id` — integer question ID.

**Request body:** Same shape as create, all fields optional.

**Errors:**
- `404` if question `id` does not exist.
- `404` if `subjectId` references a non-existent subject.

---

#### DELETE `/api/faq/question/:id`

Deletes a question.

**Permission:** `canDeleteFaq`

**Path param:** `id` — integer question ID.

**Errors:**
- `404` if question `id` does not exist.

**Success response:**

```json
{ "message": "FAQ question deleted successfully." }
```

---

### Content

#### GET `/api/faq/content?subjectId=<id>`

Returns all content items for a given subject, sorted by `id ASC` (content has no `order` column — see [Ordering Logic](#ordering-logic)).

**Permission:** `canViewFaq`

**Query param:** `subjectId` (integer, required)

**Response:**

```json
[
  {
    "id": 5,
    "name": "Intro Video",
    "description": "A 2-minute walkthrough",
    "type": "youtube",
    "link": "https://www.youtube.com/watch?v=abc123",
    "videoLink": null,
    "protectedLink": null,
    "protectedVideoLink": null,
    "thumbnail": "https://cdn.example.com/thumb.jpg",
    "subjectId": 3
  }
]
```

**Errors:**
- `404` if `subjectId` does not exist.

---

#### POST `/api/faq/content`

Creates a new content item under a subject.

**Permission:** `canCreateFaq`

**Request body:**

```json
{
  "name": "Intro Video",
  "description": "A 2-minute walkthrough",
  "type": "youtube",
  "link": "https://www.youtube.com/watch?v=abc123",
  "videoLink": null,
  "protectedLink": null,
  "protectedVideoLink": null,
  "thumbnail": "https://cdn.example.com/thumb.jpg",
  "subjectId": 3
}
```

| Field                | Type   | Required | Notes                                          |
|----------------------|--------|----------|------------------------------------------------|
| `name`               | string | yes      | Display name                                   |
| `description`        | string | no       |                                                |
| `type`               | string | yes      | One of the seven content types (see below)     |
| `link`               | string | no       | Public URL; required+validated for `youtube`   |
| `videoLink`          | string | no       | Video URL; validated for Vimeo if `video` type |
| `protectedLink`      | string | no       | Signed/private variant of `link`               |
| `protectedVideoLink` | string | no       | Signed/private variant of `videoLink`          |
| `thumbnail`          | string | no       |                                                |
| `subjectId`          | number | yes      | Must reference an existing subject             |

**Link validation** is applied before insert (see [Content Types Reference](#content-types-reference)).

**Errors:**
- `404` if `subjectId` does not exist.
- `400` for invalid link format (YouTube/Vimeo rules).

---

#### PATCH `/api/faq/content/:id`

Updates a content item. All fields are optional.

**Permission:** `canEditFaq`

**Path param:** `id` — integer content ID.

**Request body:** Same shape as create, all fields optional.

**Merge behaviour for link validation:** When `type` or link fields are omitted, the service merges the incoming values with the current DB record before re-validating. This ensures the validation always sees the full final state.

**Errors:**
- `404` if content `id` does not exist.
- `404` if `subjectId` references a non-existent subject.
- `400` for invalid link format after merge.

---

#### DELETE `/api/faq/content/:id`

Deletes a content item.

**Permission:** `canDeleteFaq`

**Path param:** `id` — integer content ID.

**Errors:**
- `404` if content `id` does not exist.

**Success response:**

```json
{ "message": "FAQ content deleted successfully." }
```

---

### Mappings

Mappings link a FAQ subject tree to a specific course, a specific platform, or both. A subject mapped without a course or platform ID is effectively global.

#### POST `/api/faq/mapping`

Creates a subject ↔ course/platform mapping.

**Permission:** `canCreateFaq`

**Request body:**

```json
{
  "faqSubjectId": 1,
  "courseId": 42,
  "platformId": 7
}
```

| Field          | Type   | Required | Notes                                      |
|----------------|--------|----------|--------------------------------------------|
| `faqSubjectId` | number | yes      | Must reference an existing subject         |
| `courseId`     | number | no       | Must reference an existing course if given |
| `platformId`   | number | no       | Must reference an existing platform if given |

**Errors:**
- `404` if `faqSubjectId`, `courseId`, or `platformId` does not exist.
- `409` if the exact `(faqSubjectId, courseId, platformId)` combination already exists.

---

#### DELETE `/api/faq/mapping/:id`

Removes a mapping.

**Permission:** `canDeleteFaq`

**Path param:** `id` — integer mapping ID.

**Errors:**
- `404` if mapping `id` does not exist.

**Success response:**

```json
{ "message": "FAQ mapping removed successfully." }
```

---

### File Upload

Both upload routes use `multipart/form-data` with a single `file` field. Files are uploaded to Vultr object storage (S3-compatible). The returned URL can then be used as a `link`, `protectedLink`, `thumbnail`, etc. when creating or updating content.

Maximum file size: **50 MB**.

**Permission for both:** `canCreateFaq`

## Business Rules & Constraints

### Subject Tree Integrity

- A subject can be moved to a new parent by patching `faqSubjectId`. The service prevents:
  - Self-parenting (`faqSubjectId === id`) → `400`.
  - Circular reparenting (making a node its own descendant) → `400`. The check walks the full ancestor chain via a Map built from a single DB query.
- A subject can only be deleted when it has zero children, zero questions, zero content, and zero mappings. All four counts are fetched in a single `Promise.all`.

### Mapping Uniqueness

The combination `(faqSubjectId, courseId, platformId)` must be unique in `FaqToCourseNdPlatform`. Duplicate inserts return `409 Conflict` rather than silently overwriting.

### Content Link Validation

Validated synchronously in the service before any DB write. Rules applied per type:

- `youtube`: `link` or `videoLink` must match `(https?://)?(www\.)?(youtube\.com|youtu\.be)/.+` (case-insensitive). Missing or non-matching URL → `400`.
- `video`: if `videoLink` or `link` contains "vimeo", the full URL is tested against `(https?://)?(www\.)?(player\.)?vimeo\.com/.+`. Malformed Vimeo URL → `400`.
- All other types: no URL format enforcement.

On PATCH, the merged state (existing DB value + incoming DTO) is validated, so you can safely update only the `type` without re-sending link fields.

---

## Content Types Reference

The `type` field on `FaqContent` must be one of:

| Value      | Intended use                                       | Link validation            |
|------------|----------------------------------------------------|----------------------------|
| `youtube`  | YouTube embed                                      | URL must be YouTube domain |
| `video`    | Direct video file or Vimeo embed                   | Vimeo URLs are validated   |
| `pdf`      | PDF document (link to file)                        | None                       |
| `document` | Word doc, Google Doc, or any document URL          | None                       |
| `image`    | Image file URL                                     | None                       |
| `link`     | Generic external URL                               | None                       |
| `file`     | Any binary file (uploaded via the upload endpoints)| None                       |

---

## Ordering Logic

All list endpoints sort results using the same private comparator:

```
Primary:   order ASC, NULLs last
Secondary: id ASC (stable tiebreaker)
```

- Records with an explicit `order` value appear before records with `order = null`.
- Among records with the same `order`, lower `id` wins.
- `FaqContent` has no `order` column in the schema, so all content items sort purely by `id ASC`.

Sorting is done **in application memory** after a single `findMany` call — there is no `ORDER BY` clause sent to the database. For very large subjects (hundreds of questions/content items) this is fine; if scale becomes a concern, a DB-side `ORDER BY` is the optimization path.

---

## Error Reference

| HTTP | Code / Message                                                              | When                                                       |
|------|-----------------------------------------------------------------------------|------------------------------------------------------------|
| 400  | `A valid YouTube URL is required.`                                          | `type: youtube` with missing or malformed link             |
| 400  | `A valid Vimeo URL is required.`                                            | `type: video` with a Vimeo URL that doesn't match pattern  |
| 400  | `A subject cannot be its own parent.`                                       | PATCH subject with `faqSubjectId === id`                   |
| 400  | `Cannot reparent a subject under one of its own descendants.`               | PATCH subject would create a cycle                         |
| 400  | `No file provided.`                                                         | Upload endpoint called without a file                      |
| 403  | Forbidden (from `checkPermission`)                                          | Employee lacks the required permission key                 |
| 404  | `FAQ subject not found.`                                                    | Subject ID does not exist in any subject operation         |
| 404  | `FAQ question not found.`                                                   | Question ID does not exist                                 |
| 404  | `FAQ content not found.`                                                    | Content ID does not exist                                  |
| 404  | `FAQ mapping not found.`                                                    | Mapping ID does not exist on delete                        |
| 404  | `Course not found.`                                                         | `courseId` in mapping does not exist                       |
| 404  | `Platform not found.`                                                       | `platformId` in mapping does not exist                     |
| 409  | `Cannot delete a subject that has child subjects. Delete or move them first.` | DELETE subject with children                             |
| 409  | `Cannot delete a subject that still has questions or contents. Remove them first.` | DELETE subject with questions or content           |
| 409  | `Cannot delete a subject that is mapped to a course/platform. Remove the mappings first.` | DELETE subject with active mappings         |
| 409  | `This mapping already exists.`                                              | POST mapping with duplicate `(subjectId, courseId, platformId)` |

---

## Source Files

| File | Purpose |
|------|---------|
| `src/command/command.controller.ts` lines 4153–4320 | Route definitions for all FAQ endpoints |
| `src/command/command.service.ts` lines 17372–17716 | All business logic, validation, and DB queries |
| `src/command/dto/faq/create-faq-subject.dto.ts` | Subject create payload |
| `src/command/dto/faq/update-faq-subject.dto.ts` | Subject update payload |
| `src/command/dto/faq/create-faq-question.dto.ts` | Question create payload |
| `src/command/dto/faq/update-faq-question.dto.ts` | Question update payload |
| `src/command/dto/faq/get-faq-questions.dto.ts` | Subject ID query param for GET questions |
| `src/command/dto/faq/create-faq-content.dto.ts` | Content create payload |
| `src/command/dto/faq/update-faq-content.dto.ts` | Content update payload |
| `src/command/dto/faq/get-faq-content.dto.ts` | Subject ID query param for GET content |
| `src/command/dto/faq/create-faq-mapping.dto.ts` | Mapping create payload |
| `src/command/dto/faq/faq-content-types.ts` | Enum of valid content type strings |
| `prisma/schema.prisma` lines 1931–1976 | DB schema for all four FAQ models |
| `src/common/utils/check-permission.ts` | Recursive permission resolver used by all FAQ service methods |
