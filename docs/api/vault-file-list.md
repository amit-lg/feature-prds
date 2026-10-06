# List / Search Vault Files

Returns vault files (newest first) with their `link`, `name` and `type`. Supports
name search and pagination via query params.

---

## Endpoint

```
GET /api/command/vault-files
```

> The global `/api` prefix applies — the full path is `/api/command/vault-files`.

---

## Auth & headers

| Header | Value | Required |
|---|---|---|
| `Authorization` | `Bearer <employee JWT>` | ✅ Yes — employee token (`path: 'command'`) |
| `Origin` | your app origin | ✅ Sent automatically by the browser (used to resolve the platform) |

---

## Query params

| Param | Type | Required | Notes |
|---|---|---|---|
| `search` | string | ❌ No | Case-insensitive **substring** match on the file `name`. Omit to return everything. |
| `page` | number | ❌ No | Zero-based page number. **50 files per page.** Omit or `0` for the first page. |

Examples:

```
GET /api/command/vault-files
GET /api/command/vault-files?search=diagram
GET /api/command/vault-files?search=diagram&page=1
```

---

## Response

### `200 OK`

A plain array of files, ordered newest first:

```json
[
  {
    "id": 501,
    "link": "https://<vultr-cdn>/CRM/vault/file_<uuid>.png",
    "name": "diagram.png",
    "type": "image/png"
  },
  {
    "id": 498,
    "link": "https://<vultr-cdn>/CRM/vault/file_<uuid>.pdf",
    "name": "offer-letter.pdf",
    "type": "application/pdf"
  }
]
```

- An empty result set returns `[]` (not an error).
- `link` and `name` can be `null` for legacy rows; `type` is always present.

### Errors

| Status | When | Body (`message`) |
|---|---|---|
| `401` | Missing / invalid / expired token, or platform mismatch | Unauthorized |

---

## Response type (TypeScript)

```ts
export interface VaultFileListItem {
  id: number;
  link: string | null;
  name: string | null;
  type: string;
}

export type VaultFileListResponse = VaultFileListItem[];
```

---

## Example — axios

```ts
import axios from 'axios';

export async function listVaultFiles(
  opts?: { search?: string; page?: number },
): Promise<VaultFileListResponse> {
  const { data } = await axios.get(`${API_BASE}/api/command/vault-files`, {
    params: {
      ...(opts?.search ? { search: opts.search } : {}),
      ...(opts?.page != null ? { page: opts.page } : {}),
    },
    headers: { Authorization: `Bearer ${employeeToken}` },
  });
  return data;
}
```

## Example — fetch

```ts
const params = new URLSearchParams();
if (search) params.set('search', search);
if (page != null) params.set('page', String(page));

const res = await fetch(
  `${API_BASE}/api/command/vault-files?${params.toString()}`,
  { headers: { Authorization: `Bearer ${employeeToken}` } },
);
if (!res.ok) throw new Error((await res.json()).message);
const files: VaultFileListResponse = await res.json();
```

---

## Example — debounced search (React)

```tsx
function useVaultFileSearch() {
  const [query, setQuery] = useState('');
  const [files, setFiles] = useState<VaultFileListItem[]>([]);

  useEffect(() => {
    const t = setTimeout(() => {
      listVaultFiles({ search: query || undefined }).then(setFiles);
    }, 300); // debounce keystrokes
    return () => clearTimeout(t);
  }, [query]);

  return { query, setQuery, files };
}
```

---

## Integration notes

- **Pagination is 50 per page.** If a page returns fewer than 50 items, you've
  reached the end. Increment `page` for the next batch.
- **`search` matches the name only** (case-insensitive substring), not the file
  type or link.
- **`link` is a public URL** (Vultr objects are `public_read`), so it can be
  rendered (`<img src={link}>`) or downloaded directly.
- Pair with the upload endpoint — see [`vault-file-upload.md`](./vault-file-upload.md).
