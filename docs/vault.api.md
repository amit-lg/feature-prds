# Vault File Manager API (Design Spec)

> **Status: implemented in code, not yet migrated to the database.** `prisma/schema.prisma` now
> has `VaultFolder`, `VaultFolderAccess`, and `VaultFolderToCourseNdPlatform`, plus the extended
> `VaultFile` columns described below, and `npx prisma generate` has been run so the client in
> `src/generated/prisma` matches. `VaultService` lives in its own `src/vault/` module, but the
> routes themselves are defined directly on `CommandController`
> (`src/command/command.controller.ts`, `//#region vault apis`) — these are admin/employee-portal
> APIs, so they were moved out of a standalone `VaultController` to sit alongside `Events` and the
> rest of the command surface, matching the doc's original recommendation (see
> [Implementation Notes](#implementation-notes)). The whole project type-checks cleanly against the
> new schema. **What has not happened yet: no `prisma migrate dev` has been run against any
> database**, so none of the new tables/columns exist at the DB level — the app will fail at
> runtime on any vault query until that migration is applied and deployed.

Two prior drafts of this doc are worth knowing about for history: the first claimed the
`VaultFolder`/`VaultFolderAccess`/etc. models already existed in the schema — they didn't. The
second reworked the design to reuse the existing `VaultFile` model (extended with nullable
columns) instead of adding a parallel `VaultFolderFile` table, so a video's attached PDF and a
folder's uploaded file share one table. That design is what got implemented.

All routes are under the **command module**. Every request requires an employee JWT in the
`Authorization: Bearer <token>` header.

**Base URL:** `{{baseUrl}}/api/command`

---

## Authentication

All endpoints are guarded by `EmployeeAuthGuard`. Include the employee token on every request:

```
Authorization: Bearer <employee_jwt>
```

In addition, every mutating endpoint (and folder/file reads) must run through
`EmployePermissionCheck.checkPermission(...)` for a `vault.*` permission string (proposed below)
**and** through the folder-level access check described in [Access Model](#access-model) — an
employee can hold the global `vault.*` permission and still be denied on a specific folder if no
`VaultFolderAccess` grant covers them (directly or via their permission group), unless they are
the folder's creator or hold `vault.manage` (treated as vault-admin, bypasses per-folder checks).

**Proposed permission strings** (add to `permissionsStrings.txt`):
```
vault: -
    canViewVault
    canCreateFolder
    canUploadFile
    canManageAccess      (grant/revoke VaultFolderAccess — implies bypass of per-folder checks)
    canLinkCourse         (create/remove VaultFolderToCourseNdPlatform links)
```

---

## Data Model Recap

### Required migration

Nothing below exists yet. Two new models plus one link model, and additive nullable columns on
the existing `VaultFile`:

```prisma
model VaultFolder {
  id                  Int                             @id @default(autoincrement())
  name                String
  description         String?
  order               Int?
  vaultFolderId       Int?
  ParentFolder        VaultFolder?                    @relation("VaultFolderTree", fields: [vaultFolderId], references: [id])
  Folders             VaultFolder[]                   @relation("VaultFolderTree")
  Files               VaultFile[]
  Access              VaultFolderAccess[]
  CourseNdPlatform    VaultFolderToCourseNdPlatform[]
  createdByEmployeeId Int
  CreatedByEmployee   Employee                        @relation(fields: [createdByEmployeeId], references: [id])
  createdAt           DateTime                        @default(now())
  updatedAt           DateTime                        @updatedAt
}

model VaultFolderAccess {
  id                        Int                    @id @default(autoincrement())
  vaultFolderId             Int
  Folder                    VaultFolder            @relation(fields: [vaultFolderId], references: [id])
  employeeId                Int?
  Employee                  Employee?              @relation(fields: [employeeId], references: [id])
  employeePermissionGroupId Int?
  PermissionGroup           EmployeePermissionGroup? @relation(fields: [employeePermissionGroupId], references: [id])
  accessLevel               String
  grantedByEmployeeId       Int
  GrantedByEmployee         Employee               @relation("VaultAccessGrantedBy", fields: [grantedByEmployeeId], references: [id])
  createdAt                 DateTime               @default(now())
  updatedAt                 DateTime               @updatedAt
}

model VaultFolderToCourseNdPlatform {
  id            Int          @id @default(autoincrement())
  vaultFolderId Int
  Folder        VaultFolder  @relation(fields: [vaultFolderId], references: [id])
  courseId      Int?
  Course        Course?      @relation(fields: [courseId], references: [id])
  platformId    Int?
  Platform      Platform?    @relation(fields: [platformId], references: [id])
}
```

`VaultFile` (existing model, `prisma/schema.prisma:1126`) gains folder-related columns — all
nullable so the current video-attachment rows (`vaultFolderId = null`) are unaffected:

```prisma
model VaultFile {
  id                  Int                    @id @default(autoincrement())
  link                String?                // existing: file URL (Vultr Location)
  valueJson           String?                // existing: unused by the video-attach flow today
  type                String?                // existing: mimetype (was required, now optional — see below)
  name                String?                // new
  description         String?                // new
  protectedUrl        String?                // new: signed/private URL, see Open Questions
  sizeBytes           Int?                   // new
  vaultFolderId       Int?                   // new: null = not a folder file (e.g. video attachment)
  Folder              VaultFolder?           @relation(fields: [vaultFolderId], references: [id])
  uploadedByEmployeeId Int?                  // new
  UploadedByEmployee  Employee?              @relation(fields: [uploadedByEmployeeId], references: [id])
  Videos              VaultFileToVideoInfo[] // existing
}
```

`type` changes from implicitly-required (always set by `uploadVideoVault`) to explicitly optional
only in the sense that folder files also use it for mimetype — behavior for the existing
video-attach path is unchanged, it still always sets it.

| Model | Purpose |
|---|---|
| `VaultFolder` *(new)* | A folder node. Self-referential (`vaultFolderId` → parent) so folders nest arbitrarily deep. Root folders have `vaultFolderId = null`. |
| `VaultFile` *(existing, extended)* | A file — either uploaded into a folder (`vaultFolderId` set) or attached to a lecture video via `VaultFileToVideoInfo` (`vaultFolderId = null`). Same table serves both, so `link`/`type` keep their current meaning (URL, mimetype). |
| `VaultFolderAccess` *(new)* | Grants an `accessLevel` on a folder to either a single `Employee` or an `EmployeePermissionGroup`. Tracks `grantedByEmployeeId`. |
| `VaultFolderToCourseNdPlatform` *(new)* | Links a folder to a `Course` and/or `Platform`, so it surfaces in that course's/platform's context (mirrors `EventsToCourseNdPlatform`). |

**`accessLevel`** is a free-text `String` column (no DB enum). Proposed values, weakest to
strongest:

| Value | Grants |
|---|---|
| `VIEWER` | List/read folder contents and download files |
| `UPLOADER` | `VIEWER` + upload/rename/delete own files |
| `EDITOR` | `UPLOADER` + rename/reorder/delete any file, create sub-folders |
| `MANAGER` | `EDITOR` + grant/revoke access on this folder and its descendants, delete the folder |

Access is **inherited down the folder tree**: a grant on a parent folder applies to all its
descendants unless a more specific grant exists on a child (most-specific-wins).

---

## 1. Folders

### List Root Folders
```
GET /api/command/vault/folder
```
Returns top-level folders (`vaultFolderId = null`) the requesting employee has at least `VIEWER`
access to, each with a `childCount` and `fileCount` summary (not the full nested tree).

**Query params (all optional):**
| Param | Type | Description |
|---|---|---|
| `search` | string | Match folder `name` |
| `courseId` | number | Only folders linked to this course |
| `platformId` | number | Only folders linked to this platform |

### List Folder Contents (children + files)
```
GET /api/command/vault/folder/:folderId
```
Returns the folder itself plus its immediate `Folders` (sub-folders) and `Files`, each annotated
with the requesting employee's effective `accessLevel`. 403s if the employee has no access.

### Create Folder
```
POST /api/command/vault/folder
Content-Type: application/json
```
**Body:**
```json
{
  "name": "Sales Playbooks",
  "description": "Scripts and objection-handling docs",
  "vaultFolderId": null,
  "order": 1
}
```
`name` is required. `vaultFolderId` is optional (omit/`null` for a root folder). The creating
employee is set as `createdByEmployeeId` and implicitly gets `MANAGER` access. Requires
`vault.canCreateFolder`, plus `EDITOR`+ access on `vaultFolderId` if creating a sub-folder.

### Update Folder
```
PATCH /api/command/vault/folder/:folderId
Content-Type: application/json
```
**Body (all optional):** `name`, `description`, `order`, `vaultFolderId` (move to a different
parent). Requires `EDITOR`+ access.

### Delete Folder
```
DELETE /api/command/vault/folder/:folderId
```
Recursively deletes the folder, its sub-folders, files, access grants, and course/platform links.
Requires `MANAGER` access. Consider a `?force=true` guard if the folder is non-empty — return
`409 Conflict` with a `childCount`/`fileCount` summary unless `force=true` is passed.

---

## 2. Files

### List Files in a Folder
```
GET /api/command/vault/folder/:folderId/file
```
Included in [List Folder Contents](#list-folder-contents-children--files) already; this endpoint
exists for pagination when a folder has many files.

**Query params:** `page` (zero-based, default `0`), `search` (matches `name`).

### Upload File
```
POST /api/command/vault/folder/:folderId/file
Content-Type: multipart/form-data
```
**Body (form-data):**
| Field | Type | Required | Description |
|---|---|---|---|
| `file` | File | Yes | The file to upload |
| `name` | string | No | Display name (defaults to original filename) |
| `description` | string | No | |

Creates a `VaultFile` row with `vaultFolderId` set (same model the video-attach flow uses with
`vaultFolderId = null`). Uploads to Vultr S3 via `VultrService.uploadToVultr`, following the
existing `uploadVideoVault` convention but under a folder-scoped key:
`CRM/vault/folder_<folderId>_<randomString>.<ext>`, storing the returned `Location` in `link`.
`protectedUrl` is reserved for a signed/short-lived URL if the file should not be publicly
readable (set `ACL: private` on upload and mint the signed URL per-request instead of storing a
static one — the column can hold `null` until that's implemented). Sets `sizeBytes` and `type`
(mimetype, same field `uploadVideoVault` already populates) from the multer file. Requires
`UPLOADER`+ access. Sets `uploadedByEmployeeId` to the requester.

### Update File
```
PATCH /api/command/vault/folder/:folderId/file/:fileId
Content-Type: application/json
```
**Body (all optional):** `name`, `description`. To replace the file contents, delete and re-upload
(keeps history simple). Requires `UPLOADER`+ access **and** (`EDITOR`+ OR uploader === requester).

### Delete File
```
DELETE /api/command/vault/folder/:folderId/file/:fileId
```
Deletes the DB record and the underlying Vultr object (`VultrService.deleteFromVultr`). Requires
`EDITOR`+ access, or `UPLOADER` if the requester is the original uploader.

---

## 3. Access Management

### List Access Grants for a Folder
```
GET /api/command/vault/folder/:folderId/access
```
Returns each `VaultFolderAccess` row with the linked `Employee` or `EmployeePermissionGroup` and
`GrantedByEmployee`. Requires `MANAGER` access.

### Grant Access
```
POST /api/command/vault/folder/:folderId/access
Content-Type: application/json
```
**Body:**
```json
{
  "employeeId": 42,
  "employeePermissionGroupId": null,
  "accessLevel": "EDITOR"
}
```
Exactly one of `employeeId` / `employeePermissionGroupId` must be set. `accessLevel` must be one
of `VIEWER`/`UPLOADER`/`EDITOR`/`MANAGER`. `grantedByEmployeeId` is set to the requester. Requires
`MANAGER` access on the folder (or `vault.canManageAccess`).

### Update Access Level
```
PATCH /api/command/vault/folder/:folderId/access/:accessId
Content-Type: application/json
```
**Body:** `{ "accessLevel": "VIEWER" }`. Requires `MANAGER` access.

### Revoke Access
```
DELETE /api/command/vault/folder/:folderId/access/:accessId
```
Requires `MANAGER` access. A `MANAGER` cannot revoke the last remaining `MANAGER` grant on a
folder (would orphan it) — return `409 Conflict` in that case.

### My Access (effective level for the requesting employee)
```
GET /api/command/vault/folder/:folderId/access/me
```
Returns `{ "accessLevel": "EDITOR", "inheritedFrom": 12 }` (or `403` if none), where
`inheritedFrom` is the folder id the grant actually lives on if it was inherited from an ancestor.
Useful for the frontend to decide which actions to show without guessing.

---

## 4. Folder ↔ Course / Platform Links

Links a folder to a platform and/or a specific course so it surfaces in that course's/platform's
context (e.g. a "Resources" tab on a course page), mirroring
`docs/event-admin-api.md#5-event--course--platform-links`.

### Get Links
```
GET /api/command/vault/folder/:folderId/course-platform
```
Returns each link with the related `Course` and `Platform` objects.

### Add Link
```
POST /api/command/vault/folder/:folderId/course-platform
Content-Type: application/json
```
**Body:**
```json
{
  "platformId": 3,
  "courseId": 12
}
```
Both fields are optional — send only `platformId` to link at platform level, or both to scope to
one course within that platform. Requires `EDITOR`+ access and `vault.canLinkCourse`.

### Remove Link
```
DELETE /api/command/vault/folder/:folderId/course-platform/:linkId
```
`linkId` is the `id` of the `VaultFolderToCourseNdPlatform` record. Requires `EDITOR`+ access.

---

## Quick Reference

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/command/vault/folder` | List root folders |
| GET | `/api/command/vault/folder/:id` | Get folder + children + files |
| POST | `/api/command/vault/folder` | Create folder |
| PATCH | `/api/command/vault/folder/:id` | Update / move folder |
| DELETE | `/api/command/vault/folder/:id` | Delete folder (recursive) |
| GET | `/api/command/vault/folder/:id/file` | List files (paginated) |
| POST | `/api/command/vault/folder/:id/file` | Upload file (multipart) |
| PATCH | `/api/command/vault/folder/:id/file/:fid` | Rename/update file |
| DELETE | `/api/command/vault/folder/:id/file/:fid` | Delete file |
| GET | `/api/command/vault/folder/:id/access` | List access grants |
| POST | `/api/command/vault/folder/:id/access` | Grant access |
| PATCH | `/api/command/vault/folder/:id/access/:aid` | Update access level |
| DELETE | `/api/command/vault/folder/:id/access/:aid` | Revoke access |
| GET | `/api/command/vault/folder/:id/access/me` | My effective access level |
| GET | `/api/command/vault/folder/:id/course-platform` | List course/platform links |
| POST | `/api/command/vault/folder/:id/course-platform` | Add course/platform link |
| DELETE | `/api/command/vault/folder/:id/course-platform/:lid` | Remove link |

---

## Open Questions Before Implementation

1. **`protectedUrl` semantics** — is it a static signed URL refreshed by a cron, or minted
   per-request? Affects whether `VaultFile` needs an expiry column in addition to `protectedUrl`.
2. **`accessLevel` as enum** — worth a Prisma enum (`VaultAccessLevel`) instead of free string, to
   get compile-time safety; would need a migration.
3. **Module placement** — inline in `command.controller.ts` (matches Events) vs. a dedicated
   `src/vault/` module (matches CLAUDE.md's general per-feature convention). Recommend the latter
   given this feature's size (folders + files + access + links) — smaller than a full module isn't
   accurate here.
4. **User-facing (non-employee) read access** — schema only wires `Employee` into
   `VaultFolderAccess`/`VaultFolder.CreatedByEmployee`/`VaultFile.UploadedByEmployee`, so this spec
   assumes vault is employee/internal-only. If end users need to read course-linked folders, that's
   a separate `AuthGuard`-protected read surface, e.g. `GET /api/user/course/:courseId/vault` — not
   covered here.
5. **Reusing `VaultFile` vs. a dedicated table** — the existing video-attachment flow
   (`LectureService.uploadVideoVault`) never sets `name`, `sizeBytes`, or `uploadedByEmployeeId`,
   so those rows will have `vaultFolderId = null` and mostly-null new columns forever. That's fine
   functionally, but if the two use cases diverge further (e.g. folder files need versioning),
   revisit whether sharing the table is still the right call versus splitting a dedicated
   `VaultFolderFile` back out.

Questions 1 and 2 are still genuinely open (see below). Question 3 went through two rounds: first
implemented as a dedicated `src/vault/` module including its own controller, then the routes were
moved onto `CommandController` (see below) since these are admin/employee-portal APIs and belong
alongside `Events` on the command surface — only `VaultService` stayed in its own module. Question
4 is unchanged — still employee-only.

---

## Implementation Notes

- `src/command/command.controller.ts` (`//#region vault apis`) — all 19 routes from the Quick
  Reference table, defined directly on `CommandController` (matching where `Events` routes live),
  each behind `@UseGuards(EmployeeAuthGuard)` per-route (this controller doesn't use a class-level
  guard). `VaultService` is injected into `CommandController`'s constructor alongside the other
  per-feature services it already calls into (`PlatformService`, `LeadService`, etc). Middleware
  comes from `CommandModule.configure()`, which already applies `PlatformAdminCheckMiddleware` to
  the whole controller (requires the resolved `Platform` to have a `command` option, not just any
  origin match) — no separate middleware wiring needed for vault specifically.
- `src/vault/vault.module.ts` — now just registers/exports `VaultService` (no controller, no
  middleware). Imported by `CommandModule`.
- `src/vault/vault.service.ts` — all business logic and the access-control core.
- `src/vault/dto/*.ts` — `folder.dto.ts`, `file.dto.ts`, `access.dto.ts`,
  `course-platform.dto.ts`.
- `src/vault/vault-access.constants.ts` — the `VIEWER < UPLOADER < EDITOR < MANAGER` ranking used
  to compare access levels (`accessLevel` stayed a plain `String` column, per Open Question #2 —
  still unresolved, ranking is enforced in application code only).

**Effective-access resolution** (`VaultService.getEffectiveAccess`): starting at the target
folder, walk up via `vaultFolderId` toward the root. At each folder, look for `VaultFolderAccess`
rows matching the employee directly or one of their `EmployeePermissionGroup`s. The first folder
in the walk (closest to the target, i.e. most specific) with any matching grant wins — if multiple
grants match at that same folder (e.g. two different groups), the strongest of those is used. This
is the "most-specific-wins" rule from the Access Model section. `vault.manage` short-circuits the
whole walk and grants `MANAGER` everywhere.

**Folder-creator access**: rather than special-casing "the creator bypasses checks," folder
creation inserts a `VaultFolderAccess` row granting the creator `MANAGER` on their new folder
directly — so the general resolution logic already covers it without a special case.

**`protectedUrl`** (Open Question #1): left as an always-`null` column for now, per the doc's
original proposal — no signing implemented yet. Uploaded files are stored `public_read` (matching
`VultrService.uploadToVultr`'s existing default) and served via `link`.

**Known gaps / not implemented**:
- No enum for `accessLevel` (Open Question #2) — still a free `String`, validated only via
  `@IsIn(...)` in the DTOs and ranked in `vault-access.constants.ts`.
- No user-facing (non-employee) read surface (Open Question #4).
- `getFolderContents`/`getRootFolders`/`getFoldersForCourse` resolve each folder's effective
  access with an independent tree walk per folder — correct but does one or more extra queries per
  folder rather than batching. Fine at expected folder-tree sizes; revisit if a platform ends up
  with very large flat folder listings.

**Migration status**: the schema changes are written and `prisma generate` has been run, but no
`prisma migrate dev` has been run against any database yet — see the status note at the top of
this document. `.env`'s active `DATABASE_URL` points at a shared remote database
(`GrowthDbLeadTest`), so that migration was deliberately left for the developer to run explicitly
rather than applied automatically.
