# Rename / Delete Vault Files

Two endpoints for managing an existing vault file:

- **PATCH** — rename a vault file (the **name is the only editable field**).
- **DELETE** — permanently delete a vault file from both **Vultr storage** and the
  database.

Pair these with the [upload](./vault-file-upload.md) and
[list/search](./vault-file-list.md) endpoints.

---

## Auth & headers (both endpoints)

| Header | Value | Required |
|---|---|---|
| `Authorization` | `Bearer <employee JWT>` | ✅ Yes — employee token (`path: 'command'`) |
| `Origin` | your app origin | ✅ Sent automatically by the browser (used to resolve the platform) |

> The global `/api` prefix applies to every path below.

---

## 1. Rename a vault file

```
PATCH /api/command/vault-files/:id
```

Only the **display name** can be changed. The file content and everything derived
from it — `link`, `md5hash`, `type` and `sizeBytes` — are immutable. To change the
actual file, upload a new one via the upload endpoint.

### Path params

| Param | Type | Notes |
|---|---|---|
| `id` | number | The `VaultFile.id` to rename. |

### Body (`application/json`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | ✅ Yes | New display name. Non-empty. |

```json
{ "name": "system-architecture.png" }
```

### Response — `200 OK`

```json
{
  "message": "File updated successfully.",
  "file": {
    "id": 501,
    "link": "https://<vultr-cdn>/CRM/vault/file_<uuid>.png",
    "name": "system-architecture.png",
    "type": "image/png"
  }
}
```

### Errors

| Status | When | Body (`message`) |
|---|---|---|
| `400` | `name` missing or empty | validation message |
| `401` | Missing / invalid / expired token, or platform mismatch | Unauthorized |
| `404` | No vault file with that `id` | `Vault file not found.` |

---

## 2. Delete a vault file

```
DELETE /api/command/vault-files/:id
```

Permanently removes the file:

1. Detaches any video associations (`VaultFileToVideoInfo`).
2. Deletes the `VaultFile` row from the database.
3. Deletes the underlying object from **Vultr storage**.

This is **irreversible**.

### Path params

| Param | Type | Notes |
|---|---|---|
| `id` | number | The `VaultFile.id` to delete. |

### Response — `200 OK`

```json
{
  "message": "File deleted successfully.",
  "id": 501
}
```

### Errors

| Status | When | Body (`message`) |
|---|---|---|
| `401` | Missing / invalid / expired token, or platform mismatch | Unauthorized |
| `404` | No vault file with that `id` | `Vault file not found.` |

> Storage removal is best-effort: if Vultr deletion hiccups, the DB row is still
> removed (so no dangling record is left) and the request still succeeds.

---

## Response types (TypeScript)

```ts
export interface VaultFileItem {
  id: number;
  link: string | null;
  name: string | null;
  type: string;
}

export interface UpdateVaultFileResponse {
  message: string;
  file: VaultFileItem;
}

export interface DeleteVaultFileResponse {
  message: string;
  id: number;
}
```

---

## Example — axios

```ts
import axios from 'axios';

export async function renameVaultFile(
  id: number,
  name: string,
): Promise<UpdateVaultFileResponse> {
  const { data } = await axios.patch(
    `${API_BASE}/api/command/vault-files/${id}`,
    { name },
    { headers: { Authorization: `Bearer ${employeeToken}` } },
  );
  return data;
}

export async function deleteVaultFile(
  id: number,
): Promise<DeleteVaultFileResponse> {
  const { data } = await axios.delete(
    `${API_BASE}/api/command/vault-files/${id}`,
    { headers: { Authorization: `Bearer ${employeeToken}` } },
  );
  return data;
}
```

## Example — fetch

```ts
// Rename
const res = await fetch(`${API_BASE}/api/command/vault-files/${id}`, {
  method: 'PATCH',
  headers: {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${employeeToken}`,
  },
  body: JSON.stringify({ name }),
});
if (!res.ok) throw new Error((await res.json()).message);
const updated: UpdateVaultFileResponse = await res.json();

// Delete
const delRes = await fetch(`${API_BASE}/api/command/vault-files/${id}`, {
  method: 'DELETE',
  headers: { Authorization: `Bearer ${employeeToken}` },
});
if (!delRes.ok) throw new Error((await delRes.json()).message);
const deleted: DeleteVaultFileResponse = await delRes.json();
```

---

## Example — inline rename + delete (React)

```tsx
function VaultFileRow({
  file,
  onChange,
}: {
  file: VaultFileItem;
  onChange: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(file.name ?? '');
  const [busy, setBusy] = useState(false);

  async function save() {
    if (!name.trim()) return;
    setBusy(true);
    try {
      await renameVaultFile(file.id, name.trim());
      setEditing(false);
      onChange(); // refresh list
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!confirm('Delete this file permanently?')) return;
    setBusy(true);
    try {
      await deleteVaultFile(file.id);
      onChange(); // refresh list
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      {editing ? (
        <>
          <input value={name} onChange={(e) => setName(e.target.value)} />
          <button disabled={busy} onClick={save}>Save</button>
          <button disabled={busy} onClick={() => setEditing(false)}>Cancel</button>
        </>
      ) : (
        <>
          <span>{file.name}</span>
          <button disabled={busy} onClick={() => setEditing(true)}>Rename</button>
          <button disabled={busy} onClick={remove}>Delete</button>
        </>
      )}
    </div>
  );
}
```

---

## Integration notes

- **Rename only touches the name.** The `link` stays the same after a rename, so any
  `<img src={link}>` or download URL you already hold remains valid.
- **Delete is permanent and clears storage.** After a successful delete, the `link`
  stops resolving — remove the item from your UI list immediately (or re-fetch).
- **Deleting a deduplicated file:** uploads are deduplicated by md5 hash, so a single
  `VaultFile` row may be referenced from multiple places in your UI. Deleting it
  removes the one shared object; make sure nothing else still points at that `id`.
- **Always handle `404`** — the file may have already been deleted by another user;
  treat it as "already gone" and refresh your list.

---

## Course-resources trees: store the file id, get the name/link back on read

A vault file can be placed inside a **course-resources tree** (`GET/POST
command/courseresources/:id`). In that tree a file lives on a **leaf node** as a
link. **Reference the file by its id only — do not store its name or url.**

**What you POST** to `command/courseresources/:id` — each link carries just the
`VaultFile.id` (the `id` returned by the upload/list endpoints):

```json
{
  "id": "folder1/my-performance",
  "type": "leaf",
  "links": [{ "fileId": 166 }]
}
```

**What you get back** from `GET command/courseresources/:id` — the server resolves
each `fileId` against the live `VaultFile` row and injects the current `name`,
`link` (the Vultr url) and `type` alongside it:

```json
{
  "id": "folder1/my-performance",
  "type": "leaf",
  "links": [
    {
      "fileId": 166,
      "name": "my-performance.pdf",
      "link": "https://…/file_<uuid>.pdf",
      "type": "application/pdf"
    }
  ]
}
```

Because the tree stores **only the id**, a rename via `PATCH vault-files/:id` (or a
re-uploaded object) shows up automatically on the next GET — nothing in the tree
goes stale, and there is no propagation step. Practical consequences:

- **Send only `fileId` per link.** Any `name`/`link` you also send is ignored — the
  server overwrites them from the `VaultFile` row on read.
- The hydrated link fields **mirror `VaultFile`**: `name` = `VaultFile.name`,
  `link` = `VaultFile.link` (url), `type` = `VaultFile.type`.
- The leaf's own **`name`** (an optional node title) is *not* touched — set it
  yourself if you want a heading distinct from the file name.
- A link whose file was **deleted** resolves to no match, so `name`/`link` are not
  injected — only the bare `fileId` remains. Treat that as "file gone" and, if you
  need to surface it, cross-check against the list/search endpoint.
- **Legacy trees** that still stored `links[].url` (no `fileId`) keep working: the
  server matches them by url and backfills `fileId`/`name`/`link`/`type`.
