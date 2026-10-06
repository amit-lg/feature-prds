# Vault File Manager API (Design Spec)

> **Status: not yet implemented.** The Prisma schema already defines the Vault File Manager models
> (`VaultFolder`, `VaultFolderFile`, `VaultFolderAccess`, `VaultFolderToCourseNdPlatform` —
> see `prisma/schema.prisma`, `// #region Vault File Manager`), but no controller/service exists
> yet. This document specs the endpoints to build against that schema, following the conventions
> of the existing `event-admin-api` (folder/file/access/course-link shape is structurally the same
> pattern as Events → Locations/Options/CourseNdPlatform).
>
> Recommended placement: add these routes to `src/command/command.controller.ts` under
> `@Controller('command')` (same module Events live in), backed by a new `VaultService`, OR break
> it out into its own `src/vault/` module if it grows large. Examples below assume the former for
> consistency with `docs/event-admin-api.md`.

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

| Model | Purpose |
|---|---|
| `VaultFolder` | A folder node. Self-referential (`vaultFolderId` → parent) so folders nest arbitrarily deep. Root folders have `vaultFolderId = null`. |
| `VaultFolderFile` | A file uploaded into a folder. Stores `url` (public) and `protectedUrl` (access-checked), `mimeType`, `sizeBytes`. |
| `VaultFolderAccess` | Grants an `accessLevel` on a folder to either a single `Employee` or an `EmployeePermissionGroup`. Tracks `grantedByEmployeeId`. |
| `VaultFolderToCourseNdPlatform` | Links a folder to a `Course` and/or `Platform`, so it surfaces in that course's/platform's context (mirrors `EventsToCourseNdPlatform`). |

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

Uploads to Vultr S3 via `VultrService.uploadToVultr` (object key convention:
`CRM/vault/folder_<folderId>/<timestamp>_<randomString>.<ext>`), storing the returned
`Location` in `url`. `protectedUrl` is reserved for a signed/short-lived URL if the file should
not be publicly readable (set `ACL: private` on upload and mint the signed URL per-request instead
of storing a static one — the column can hold `null` until that's implemented). Sets
`sizeBytes`/`mimeType` from the multer file. Requires `UPLOADER`+ access. Sets
`uploadedByEmployeeId` to the requester.

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
   per-request? Affects whether `VaultFolderFile` needs an expiry column.
2. **`accessLevel` as enum** — worth a Prisma enum (`VaultAccessLevel`) instead of free string, to
   get compile-time safety; would need a migration.
3. **Module placement** — inline in `command.controller.ts` (matches Events) vs. a dedicated
   `src/vault/` module (matches CLAUDE.md's general per-feature convention). Recommend the latter
   given this feature's size (folders + files + access + links) — smaller than a full module isn't
   accurate here.
4. **User-facing (non-employee) read access** — schema only wires `Employee` into
   `VaultFolderAccess`/`CreatedByEmployee`/`UploadedByEmployee`, so this spec assumes vault is
   employee/internal-only. If end users need to read course-linked folders, that's a separate
   `AuthGuard`-protected read surface, e.g. `GET /api/user/course/:courseId/vault` — not covered
   here.
