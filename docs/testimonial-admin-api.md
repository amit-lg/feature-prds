# Testimonial Admin API — Developer Reference

This document covers the full testimonial management system exposed through the Command controller. It is intended for backend developers and admin-panel engineers working with the Growth Command platform.

---

## Table of Contents

1. [Overview](#overview)
2. [Data Model](#data-model)
3. [Permissions](#permissions)
4. [Authentication](#authentication)
5. [API Endpoints](#api-endpoints)
   - [Categories](#categories)
   - [Testimonials](#testimonials)
   - [Category Mappings](#category-mappings)
   - [Course & Platform Mappings](#course--platform-mappings)
   - [File Upload](#file-upload)
6. [Business Rules & Constraints](#business-rules--constraints)
7. [Error Reference](#error-reference)
8. [Frontend Instructions](#frontend-instructions)
9. [Source Files](#source-files)

---

## Overview

The testimonial system lets admins collect student testimonials, organize them into a category tree, and publish them scoped to a course, a platform, or globally. The shape is:

```
UserTestimonialCategory (tree, unlimited depth)
  └── UserTestimonialCategoryToTestimonial  (many-to-many: category ↔ testimonial)

UserTestimonials
  ├── UserTestimonialCategoryToTestimonial[]     (many-to-many: testimonial ↔ category)
  └── UserTestimonialToCoursendPlatform[]        (mapping: testimonial ↔ course/platform)
```

A testimonial is a standalone record (name, review, profile picture, etc.) that can be tagged into any number of categories and published against any number of course/platform combinations, each with its own slug and featured flags. This is the same admin-panel pattern used by the [FAQ admin API](faq-admin.md) — a tree of categories, leaf records, and separate mapping endpoints — adapted to testimonials' many-to-many shape.

All endpoints live under the global route prefix `/api` and are grouped under the `/command` controller, so the full base path is:

```
/api/testimonial/...
```

Every endpoint requires an authenticated **employee** (admin) JWT — user tokens are rejected.

---

## Data Model

### UserTestimonialCategory

| Column        | Type    | Required | Description                                                        |
|---------------|---------|----------|----------------------------------------------------------------------|
| `id`          | Int     | auto     | Primary key                                                        |
| `name`        | String  | yes      | Display name of the category                                       |
| `description` | String  | no       | Short description                                                  |
| `testimonialId` | Int   | no       | **Parent category id** (self-relation). `null` means a root category. The column is misleadingly named in the database — it does not reference a testimonial. The API exposes it as `parentCategoryId`. |

A category may have any number of child categories and any number of testimonials mapped to it. Deleting a category requires both to be empty first.

### UserTestimonials

| Column        | Type    | Required | Description                                            |
|---------------|---------|----------|----------------------------------------------------------|
| `id`          | Int     | auto     | Primary key                                             |
| `fname`       | String  | no       | First name                                              |
| `lname`       | String  | no       | Last name                                               |
| `profile`     | String  | no       | Profile picture URL                                     |
| `gender`      | String  | no       | Free-text gender field                                  |
| `designation` | String  | no       | Job title / role shown alongside the testimonial         |
| `review`      | String  | no       | The testimonial text                                     |
| `social`      | Json    | no       | Arbitrary social links, e.g. `{ "linkedin": "...", "twitter": "..." }` |
| `userId`      | Int     | no       | Optional link to an existing platform `User`             |
| `createdAt`   | DateTime| auto     |                                                          |
| `updatedAt`   | DateTime| auto     |                                                          |

### UserTestimonialCategoryToTestimonial (Category mapping)

| Column        | Type | Required | Description                    |
|---------------|------|----------|----------------------------------|
| `id`          | Int  | auto     | Primary key                    |
| `categoryId`  | Int  | yes      | FK → UserTestimonialCategory   |
| `testimonialId` | Int | yes    | FK → UserTestimonials          |

The combination `(testimonialId, categoryId)` is unique — creating a duplicate mapping returns `409 Conflict`.

### UserTestimonialToCoursendPlatform (Course/Platform mapping)

| Column             | Type    | Required | Description                                    |
|--------------------|---------|----------|--------------------------------------------------|
| `id`               | Int     | auto     | Primary key                                    |
| `testimonialId`    | Int     | yes      | FK → UserTestimonials                          |
| `courseId`         | Int     | no       | FK → Course. `null` = all courses              |
| `platformId`       | Int     | no       | FK → Platform. `null` = all platforms          |
| `slug`             | String  | no       | Grouping slug used by the public testimonial feed |
| `platformFeatured` | Boolean | no       | Whether to feature this testimonial platform-wide |
| `courseFeatured`   | Boolean | no       | Whether to feature this testimonial on the course page |

The combination `(testimonialId, courseId, platformId)` is unique — creating a duplicate mapping returns `409 Conflict`.

This is the same table read by the public-facing `GET /platform/testimonial` endpoint ([src/platform/platform.service.ts](../src/platform/platform.service.ts)), so mappings created here appear on the storefront immediately.

---

## Permissions

All service methods check the calling employee's permission via `checkPermission()`. The four permission strings used are:

| Permission Key         | Grants access to                                                      |
|-------------------------|-------------------------------------------------------------------------|
| `canViewTestimonial`   | GET category tree, GET testimonials, GET testimonial by id             |
| `canCreateTestimonial` | POST category, testimonial, category-mapping, mapping; file upload     |
| `canEditTestimonial`   | PATCH category, testimonial, mapping                                   |
| `canDeleteTestimonial` | DELETE category, testimonial, category-mapping, mapping                |

These keys are resolved through the recursive employee permission/group tree in `src/common/utils/check-permission.ts`. An employee without the relevant key receives `403 Forbidden`.

---

## Authentication

All testimonial endpoints use `@UseGuards(EmployeeAuthGuard)`. The guard expects:

```
Authorization: Bearer <employee-jwt>
```

The JWT must encode `path: 'command'` and a `platformId` that matches the request's `origin` or `dauth` header. Requests without a resolvable platform are rejected before the guard runs (`PlatformCheckMiddleware`).

---

## API Endpoints

### Categories

#### GET `/api/testimonial/category/tree`

Returns the full category hierarchy as a nested tree.

**Permission:** `canViewTestimonial`

**Response:**

```json
[
  {
    "id": 1,
    "name": "Course Reviews",
    "description": "Reviews left after course completion",
    "children": [
      {
        "id": 3,
        "name": "CFA Level 1",
        "description": null,
        "children": []
      }
    ]
  }
]
```

- Root categories (`parentCategoryId = null`) form the top-level array.
- Each node's `children` array is recursively built in memory (single DB query, O(n) tree build).
- Siblings are sorted alphabetically by `name`, then by `id` as a tiebreaker.

---

### Testimonials

#### GET `/api/testimonial?categoryId=<id>`

Returns testimonials, optionally filtered by category, most recent first. Each result includes its linked `User` (if any), all mapped categories, and all course/platform mappings.

**Permission:** `canViewTestimonial`

**Query param:** `categoryId` (integer, optional)

**Errors:**
- `404` if `categoryId` does not exist.

---

#### GET `/api/testimonial/:id`

Returns a single testimonial with the same nested includes as the list endpoint.

**Permission:** `canViewTestimonial`

**Errors:**
- `404` if testimonial `id` does not exist.

---

#### POST `/api/testimonial`

Creates a new testimonial.

**Permission:** `canCreateTestimonial`

**Request body:**

```json
{
  "fname": "Aditi",
  "lname": "Sharma",
  "profile": "https://cdn.example.com/aditi.jpg",
  "gender": "female",
  "designation": "CFA Level 2 candidate",
  "review": "The lecture guide kept me on track for the whole prep cycle.",
  "social": { "linkedin": "https://linkedin.com/in/aditi" },
  "userId": 4821
}
```

All fields are optional. `userId`, if given, must reference an existing platform `User` (`404` otherwise).

---

#### PATCH `/api/testimonial/:id`

Updates a testimonial. All fields are optional; same shape as create.

**Permission:** `canEditTestimonial`

**Errors:**
- `404` if testimonial `id` does not exist.
- `404` if `userId` references a non-existent user.

---

#### DELETE `/api/testimonial/:id`

Deletes a testimonial along with its category mappings and course/platform mappings, in a single transaction.

**Permission:** `canDeleteTestimonial`

**Errors:**
- `404` if testimonial `id` does not exist.

**Success response:**

```json
{ "message": "Testimonial deleted successfully." }
```

---

### Category Mappings

#### POST `/api/testimonial/category-mapping`

Tags a testimonial into a category.

**Permission:** `canCreateTestimonial`

**Request body:**

```json
{ "testimonialId": 42, "categoryId": 1 }
```

**Errors:**
- `404` if `testimonialId` or `categoryId` does not exist.
- `409` if this testimonial is already mapped to this category.

---

#### DELETE `/api/testimonial/category-mapping/:id`

Removes a category mapping (does not delete the testimonial or the category).

**Permission:** `canDeleteTestimonial`

**Errors:**
- `404` if mapping `id` does not exist.

**Success response:**

```json
{ "message": "Testimonial category mapping removed successfully." }
```

---

### Course & Platform Mappings

Mappings link a testimonial to a specific course, a specific platform, or both, and carry the `slug` / `platformFeatured` / `courseFeatured` flags the public storefront reads.

#### POST `/api/testimonial/mapping`

**Permission:** `canCreateTestimonial`

**Request body:**

```json
{
  "testimonialId": 42,
  "courseId": 7,
  "platformId": 3,
  "slug": "cfa-l1",
  "platformFeatured": true,
  "courseFeatured": false
}
```

| Field              | Type    | Required | Notes                                        |
|--------------------|---------|----------|-------------------------------------------------|
| `testimonialId`    | number  | yes      | Must reference an existing testimonial         |
| `courseId`         | number  | no       | Must reference an existing course if given; `null` = all courses |
| `platformId`       | number  | no       | Must reference an existing platform if given; `null` = all platforms |
| `slug`             | string  | no       |                                                 |
| `platformFeatured` | boolean | no       |                                                 |
| `courseFeatured`   | boolean | no       |                                                 |

**Errors:**
- `404` if `testimonialId`, `courseId`, or `platformId` does not exist.
- `409` if the exact `(testimonialId, courseId, platformId)` combination already exists.

---

#### DELETE `/api/testimonial/mapping/:id`

**Permission:** `canDeleteTestimonial`

**Errors:**
- `404` if mapping `id` does not exist.

**Success response:**

```json
{ "message": "Testimonial mapping removed successfully." }
```

---

### File Upload

#### POST `/api/testimonial/upload`

Uploads a profile picture to Vultr object storage (S3-compatible), under the `testimonial/<uuid>-<original-filename>` key. The returned URL can be used as `profile` when creating or updating a testimonial.

**Permission:** `canCreateTestimonial`

**Request:** `multipart/form-data`, field name `file`. Maximum file size: **50 MB**.

**Response:**

```json
{ "url": "https://vultr-cdn.example.com/testimonial/550e8400-...-photo.jpg" }
```

**Errors:**
- `400` if no file is provided.

---

## Business Rules & Constraints

### Category Tree Integrity

- A category can be moved to a new parent by patching `parentCategoryId`. The service prevents:
  - Self-parenting (`parentCategoryId === id`) → `400`.
  - Circular reparenting (making a node its own descendant) → `400`. The check walks the full ancestor chain via a Map built from a single DB query.
- A category can only be deleted when it has zero children and zero testimonials mapped to it. Both counts are fetched in a single `Promise.all`.

### Mapping Uniqueness

- `(testimonialId, categoryId)` must be unique in `UserTestimonialCategoryToTestimonial`.
- `(testimonialId, courseId, platformId)` must be unique in `UserTestimonialToCoursendPlatform`.

Duplicate inserts return `409 Conflict` rather than silently overwriting.

### Testimonial Deletion Cascade

Deleting a testimonial also deletes its category mappings and course/platform mappings, in one `$transaction`, since the underlying foreign keys have no `ON DELETE CASCADE`.

---

## Error Reference

| HTTP | Message                                                                              | When                                                              |
|------|---------------------------------------------------------------------------------------|---------------------------------------------------------------------|
| 400  | `A category cannot be its own parent.`                                               | PATCH category with `parentCategoryId === id`                     |
| 400  | `Cannot reparent a category under one of its own descendants.`                       | PATCH category would create a cycle                                |
| 400  | `No file provided.`                                                                   | Upload endpoint called without a file                              |
| 403  | Forbidden (from `checkPermission`)                                                    | Employee lacks the required permission key                         |
| 404  | `Testimonial category not found.`                                                     | Category ID does not exist                                         |
| 404  | `Testimonial not found.`                                                              | Testimonial ID does not exist                                      |
| 404  | `Testimonial category mapping not found.`                                             | Category mapping ID does not exist on delete                       |
| 404  | `Testimonial mapping not found.`                                                       | Course/platform mapping ID does not exist                          |
| 404  | `User not found.`                                                                     | `userId` on a testimonial does not exist                           |
| 404  | `Course not found.`                                                                   | `courseId` in a mapping does not exist                             |
| 404  | `Platform not found.`                                                                 | `platformId` in a mapping does not exist                           |
| 409  | `Cannot delete a category that has child categories. Delete or move them first.`      | DELETE category with children                                      |
| 409  | `Cannot delete a category that still has testimonials mapped to it. Remove them first.` | DELETE category with testimonials still mapped                   |
| 409  | `This testimonial is already mapped to this category.`                                | POST category-mapping with duplicate `(testimonialId, categoryId)` |
| 409  | `This mapping already exists.`                                                        | POST mapping with duplicate `(testimonialId, courseId, platformId)` |

---

## Frontend Instructions

### 1. App Layout

Follow the same two-pane layout used by the FAQ admin screen — a category tree on the left, testimonial records on the right:

```
┌───────────────────────┐  ┌─────────────────────────────────┐
│ CATEGORIES        [+] │  │  Testimonials in "CFA Level 1"   │
├───────────────────────┤  │                        [+ New]   │
│ ▾ Course Reviews       │  ├───────────────────────────────────┤
│    ▸ CFA Level 1  ●    │  │ [👤] Aditi Sharma                │
│    ▸ CFA Level 2       │  │      "The lecture guide kept..." │
│ ▾ Alumni Stories       │  │      [Edit] [Mappings] [Delete]  │
│    ▸ Placements        │  ├───────────────────────────────────┤
│                        │  │ [👤] Rahul Verma                 │
│ [All testimonials]     │  │      ...                         │
└───────────────────────┘  └─────────────────────────────────┘
```

- Build the tree from `GET /testimonial/category/tree` once on load; render it recursively (it's already sorted).
- Selecting a category calls `GET /testimonial?categoryId=<id>` to populate the right pane. An "All testimonials" pseudo-node at the top calls `GET /testimonial` with no `categoryId`.
- A testimonial can belong to more than one category — don't treat the tree selection as "the" owner of a testimonial, just as a filter. Reflect this in the UI (e.g. show category chips on each card, not a single breadcrumb).

### 2. Creating a Testimonial

1. Open the "New testimonial" form with fields for `fname`, `lname`, `designation`, `gender`, `review`, and a profile-picture picker.
2. On image select, immediately `POST /testimonial/upload` (`multipart/form-data`, field `file`) and store the returned `url` — don't wait for the rest of the form to submit. Show a spinner on the avatar slot while it uploads.
3. On save, `POST /testimonial` with the text fields plus `profile: <uploaded url>`. If the testimonial is linked to a real student, let the admin search/select a `User` and send `userId` — this is what lets the public storefront pull the user's own social links as a fallback (see `src/platform/platform.service.ts`'s `getTestimonials`).
4. If the form was opened from within a category (step 1's right pane), immediately follow up with `POST /testimonial/category-mapping` using the new testimonial's `id` — creating a testimonial does **not** auto-tag it into the category you were viewing.

### 3. Editing / Tagging Categories

- Editing text fields is a plain `PATCH /testimonial/:id`.
- Category tagging is managed separately: show the testimonial's current categories (from the `Category` array already included in the list/detail response) as removable chips, plus an "Add to category" picker.
  - Add: `POST /testimonial/category-mapping { testimonialId, categoryId }`.
  - Remove: `DELETE /testimonial/category-mapping/:id` using the mapping's own `id` (not the category id) — read it off the `Category[]` array in the testimonial response.
- A `409` on add means it's already tagged — treat this as a no-op success rather than surfacing an error (the chip should already be showing, so this shouldn't normally happen from the UI, but can if two admins edit concurrently).

### 4. Publishing (Course & Platform Mappings)

This is the part that controls what actually shows up on the public site, so give it its own panel/modal rather than burying it in the edit form — open it via the "Mappings" action on each testimonial card.

- List existing mappings from the `CourseNdPlatform` array already included on the testimonial.
- "Publish to a course/platform" = `POST /testimonial/mapping` with `testimonialId` plus any of `courseId`, `platformId`, `slug`, `platformFeatured`, `courseFeatured`. Leaving `courseId`/`platformId` blank means "all courses" / "all platforms" — make that explicit in the UI copy (e.g. a "Global" toggle) so admins don't leave them blank by accident.
- `platformFeatured` / `courseFeatured` are what decide whether a testimonial shows in a "Featured" carousel vs. the general list — expose them as two independent checkboxes on each mapping row, not a single "featured" toggle.
- Toggling those checkboxes, or editing `slug`, is `PATCH /testimonial/mapping/:id` — course/platform themselves can't be changed on an existing mapping, only the flags. To move a testimonial to a different course, delete the mapping and create a new one.
- Removing a publish target is `DELETE /testimonial/mapping/:id`. This does not delete the testimonial itself.

### 5. Deleting a Testimonial

`DELETE /testimonial/:id` removes the testimonial **and** all of its category and course/platform mappings in one call — there's no need to unlink mappings first from the UI. Warn the admin in the confirm dialog if the testimonial currently has any `platformFeatured`/`courseFeatured` mappings, since deleting it will pull it off the live site immediately.

### 6. Error Handling Notes

- Every mutating endpoint can return `403` if the logged-in employee lacks the relevant `canView/Create/Edit/DeleteTestimonial` permission — hide the corresponding buttons up front using the employee's permission list rather than relying on the error, but still handle the `403` gracefully (session/permissions can change mid-session).
- `409` responses (duplicate category mapping, duplicate course/platform mapping) are expected, recoverable states, not bugs — surface them as a toast ("Already published to this course") rather than a generic error screen.
- The `parentCategoryId` field on categories is a UI convenience name — the API never expects or returns the raw `testimonialId` column name for categories, so you can ignore that quirk entirely from the frontend.

---

## Quick Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/testimonial/category/tree` | Category tree |
| GET | `/api/testimonial?categoryId=` | List testimonials (optionally filtered) |
| GET | `/api/testimonial/:id` | Get one testimonial |
| POST | `/api/testimonial` | Create testimonial |
| PATCH | `/api/testimonial/:id` | Update testimonial |
| DELETE | `/api/testimonial/:id` | Delete testimonial + all mappings |
| POST | `/api/testimonial/category-mapping` | Tag testimonial into a category |
| DELETE | `/api/testimonial/category-mapping/:id` | Untag |
| POST | `/api/testimonial/mapping` | Publish to a course/platform |
| DELETE | `/api/testimonial/mapping/:id` | Unpublish |
| POST | `/api/testimonial/upload` | Upload profile picture |

---

## Source Files

| File | Purpose |
|------|---------|
| `src/command/command.controller.ts` (`//#region Testimonial`) | Route definitions for all testimonial endpoints |
| `src/command/command.service.ts` (`//#region Testimonial`) | All business logic, validation, and DB queries |
| `src/command/dto/testimonial/create-testimonial-category.dto.ts` | Category create payload |
| `src/command/dto/testimonial/update-testimonial-category.dto.ts` | Category update payload |
| `src/command/dto/testimonial/create-testimonial.dto.ts` | Testimonial create payload |
| `src/command/dto/testimonial/update-testimonial.dto.ts` | Testimonial update payload |
| `src/command/dto/testimonial/get-testimonials.dto.ts` | Category ID query param for GET testimonials |
| `src/command/dto/testimonial/create-testimonial-category-mapping.dto.ts` | Category mapping create payload |
| `src/command/dto/testimonial/create-testimonial-mapping.dto.ts` | Course/platform mapping create payload |
| `src/command/dto/testimonial/update-testimonial-mapping.dto.ts` | Course/platform mapping update payload |
| `prisma/schema.prisma` (`UserTestimonials`, `UserTestimonialCategory`, `UserTestimonialCategoryToTestimonial`, `UserTestimonialToCoursendPlatform`) | DB schema for all four testimonial models |
| `src/common/utils/check-permission.ts` | Recursive permission resolver used by all testimonial service methods |
| `src/platform/platform.service.ts` (`getTestimonials`) | Public-facing storefront read of the same tables |
