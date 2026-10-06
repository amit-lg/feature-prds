# User Watched Videos — API Reference

**Module:** Command (Employee-facing)  
**Date:** June 2026  
**Status:** 🟢 API Complete

---

## Overview

Returns paginated video lectures a specific user has watched, restricted to videos that belong to at least one course (i.e. the video has a `LectureToVideo` → `LectureInfo` → `LectureToCourse` chain). Videos that exist outside any course are excluded. Supports search by video code or lecture name. Stats always reflect the full matching dataset regardless of the current page.

---

## Authentication

```
Authorization: Bearer <employee_token>
```

**Required permission:** `canViewEnrolledUsers`  
If the employee does not have this permission, the server responds with `403 Forbidden`.

---

## Base URL

```
/api/command
```

---

## Endpoint

### Get watched videos for a user

```
GET /api/command/users/:userId/watched-videos
```

#### Path parameter

| Parameter | Type | Description |
|-----------|------|-------------|
| `userId` | integer | ID of the user whose watched videos to fetch |

#### Query parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `search` | string | No | Filter by video code (`VideoInfo.videoCode`) or lecture name (`LectureInfo.name`). Case-insensitive, partial match. |
| `page` | integer | No | 0-indexed page number. Page size fixed at **20**. Defaults to `0`. |
| `courseId` | integer | No | Filter to only videos whose lectures belong to this course. |

#### Request examples

```
GET /api/command/users/42/watched-videos
Authorization: Bearer <employee_token>
```

```
GET /api/command/users/42/watched-videos?search=algebra&page=1
Authorization: Bearer <employee_token>
```

#### Response

```json
{
  "message": "Watched Videos Fetched Successfully!",
  "stats": { ... },
  "watchedVideos": [ ... ],
  "page": 0
}
```

| Field | Description |
|-------|-------------|
| `message` | Fixed confirmation string |
| `stats` | Aggregate stats across **all** matching records (not just this page) — see below |
| `watchedVideos` | Paginated array of `UserToVideoInfo` records for this page (max 20) |
| `page` | The page that was returned |

#### `stats` shape

Stats are computed over the full matching dataset so they remain accurate across pages and can be used as-is for summary cards.

| Field | Type | Description |
|-------|------|-------------|
| `firstWatchedAt` | datetime \| null | Earliest `createdAt` across all matched watch records — when the user first watched any matching lecture |
| `lastWatchedAt` | datetime \| null | Latest `updatedAt` across all matched watch records — when the user last watched something |
| `total` | integer | Total number of matched video watch records — use as pagination denominator (`ceil(total / 20)` pages) |
| `videosCompleted` | integer | Number of matched videos where `done = true` |
| `watchTimeSeconds` | integer | Total seconds watched across all matched videos (`sum of seen`) |
| `lecturesWatched` | integer | Distinct lectures linked to the matched watched videos |
| `totalLecturesInCourses` | integer | Total distinct lectures across all courses the user has engaged with — denominator for completion rate |
| `coursesEngaged` | integer | Distinct courses that contain at least one of the matched watched videos |

**Derived values (compute on the frontend):**

| Derived stat | Formula |
|--------------|---------|
| Lecture completion % | `(lecturesWatched / totalLecturesInCourses) * 100` |
| Video completion % | `(videosCompleted / total) * 100` |
| Watch time (hours) | `watchTimeSeconds / 3600` |
| Total pages | `Math.ceil(total / 20)` |

#### `UserToVideoInfo` shape

Each entry is one video the user has watched, with the full lecture-and-course chain included.

| Field | Type | Description |
|-------|------|-------------|
| `userId` | integer | The user |
| `videoId` | integer | The video |
| `allocated` | integer \| null | Total allocated time (seconds) |
| `seen` | integer \| null | Time seen so far (seconds) |
| `done` | boolean \| null | Whether the user completed the video |
| `lastSeen` | integer \| null | Last watched position (seconds) |
| `createdAt` | datetime | When the watch record was created |
| `updatedAt` | datetime | Last update |
| `VideoInfo` | object | Full `VideoInfo` record including included relations below |

#### Included `VideoInfo` relations

```
VideoInfo
└── Lecture[]           (LectureToVideo — links this video to its lectures)
    └── Lecture         (LectureInfo — lecture details, name, etc.)
        └── Course[]    (LectureToCourse — links the lecture to its courses)
            └── Course  (Course record — name, id, etc.)
```

---

## Pagination

Page size is fixed at **20**. Pass `page` (0-indexed) to fetch subsequent pages.

```
GET /api/command/users/42/watched-videos?page=2
```

Use `stats.total` to compute the total number of pages: `Math.ceil(stats.total / 20)`.

---

## Search

`search` does a case-insensitive partial match against two fields:

| Field | Model | Example match for `search=algebra` |
|-------|-------|-------------------------------------|
| `videoCode` | `VideoInfo` | `"algebra-01"`, `"ALGEBRA_INTRO"` |
| `name` | `LectureInfo` | `"Algebra Basics"`, `"Linear Algebra"` |

A video is included if **either** field matches. Both the stats and the paginated list are scoped to the search result.

---

## How it maps to the database

Three queries run per request (two in parallel):

**Query 1 (parallel) — paginated watched videos** (`UserToVideoInfo`):

Returns the 20-record page with full includes.

**Query 2 (parallel) — stats data** (`UserToVideoInfo`):

Same `where` clause as Query 1 but fetches all matching records with a minimal `select` (just `done`, `seen`, `createdAt`, `updatedAt`, and the lecture/course ID chain). Used to compute all stats without the overhead of full includes.

**Query 3 (sequential, after Q2) — total lectures in engaged courses** (`LectureToCourse`):

Fetches distinct `lectureId` values across all `courseId`s derived from Query 2's result. Used for `totalLecturesInCourses`. Skipped if the user has no matching watched videos.

**Where clause** (shared by Q1 and Q2):

```
UserToVideoInfo.userId = :userId
AND VideoInfo must satisfy ALL of:
  - has at least one LectureToVideo → LectureInfo → LectureToCourse (in a course)
  - [if search] videoCode ILIKE :search
    OR has at least one LectureToVideo → LectureInfo where name ILIKE :search
```

**Full include chain** (Query 1 only):

| Level | Model | Relation field |
|-------|-------|---------------|
| 1 | `VideoInfo` | `VideoInfo` on `UserToVideoInfo` |
| 2 | `LectureToVideo[]` | `Lecture` on `VideoInfo` |
| 3 | `LectureInfo` | `Lecture` on `LectureToVideo` |
| 4 | `LectureToCourse[]` | `Course` on `LectureInfo` |
| 5 | `Course` | `Course` on `LectureToCourse` |

---

## Common error responses

| Status | Meaning |
|--------|---------|
| `400 Bad Request` | `userId` is not a valid integer, or `page` is not a valid integer |
| `401 Unauthorized` | Missing or invalid token |
| `403 Forbidden` | Employee does not have `canViewEnrolledUsers` permission |

---

## Frontend Integration

This section explains how to wire the Watched Videos panel into a user detail screen.

---

### Suggested UI layout

```
┌─ Watched Videos ──────────────────────────────────────────────────────────────┐
│                                                                                │
│  [ Search by lecture or video code... ]                                        │
│                                                                                │
│  ┌── Stats ────────────────────────────────────────────────────────────────┐  │
│  │  First watched: 2025-03-01   Last watched: 2025-08-14                   │  │
│  │  Lectures: 8 / 20  (40%)     Courses engaged: 3                         │  │
│  │  Videos completed: 10 / 42   Watch time: 6.2 hrs                        │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
│                                                                                │
│  ┌── Video row ───────────────────────────────────────────────────────┐       │
│  │  [✓] Algebra Basics  ·  CODE: alg-01  ·  Seen: 42 min / 60 min    │       │
│  │      Lecture: Introduction to Algebra  ·  Course: Math Foundation  │       │
│  └────────────────────────────────────────────────────────────────────┘       │
│  ...                                                                           │
│                                                                                │
│  [ ← Prev ]  Page 1 of 3  [ Next → ]                                          │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

### State variables

```js
const BASE_URL = '{{baseUrl}}/api/command';

function getToken() {
  return localStorage.getItem('employee_jwt');
}

let watchedVideosUserId = null;   // set when opening the panel
let watchedSearch       = '';
let watchedPage         = 0;
let watchedStats        = null;
let watchedVideos       = [];
```

---

### Fetching watched videos

```js
async function fetchWatchedVideos() {
  if (!watchedVideosUserId) return;

  const params = new URLSearchParams({ page: watchedPage });
  if (watchedSearch.trim()) params.set('search', watchedSearch.trim());

  showLoader(true);
  try {
    const res = await fetch(
      `${BASE_URL}/users/${watchedVideosUserId}/watched-videos?${params}`,
      { headers: { Authorization: `Bearer ${getToken()}` } },
    );
    if (!res.ok) throw new Error(res.status);

    const data = await res.json();
    watchedStats  = data.stats;
    watchedVideos = data.watchedVideos;
    watchedPage   = data.page;

    renderWatchedStats();
    renderWatchedVideoRows();
    renderWatchedPagination();
  } catch (e) {
    showToast('Failed to load watched videos', 'error');
    console.error(e);
  } finally {
    showLoader(false);
  }
}
```

---

### Search

Debounce the search input so you don't fire a request on every keystroke.

```js
let searchDebounceTimer = null;

function onWatchedSearchInput(value) {
  watchedSearch = value;
  clearTimeout(searchDebounceTimer);
  searchDebounceTimer = setTimeout(() => {
    watchedPage = 0;        // reset to page 0 on new search
    fetchWatchedVideos();
  }, 400);
}

function clearWatchedSearch() {
  watchedSearch = '';
  watchedPage   = 0;
  fetchWatchedVideos();
}
```

Wire to the search input:
```html
<input
  type="text"
  placeholder="Search by lecture or video code..."
  oninput="onWatchedSearchInput(this.value)"
/>
<button onclick="clearWatchedSearch()">✕</button>
```

---

### Pagination

```js
function goToWatchedPage(n) {
  watchedPage = n;
  fetchWatchedVideos();
}

function renderWatchedPagination() {
  const totalPages = Math.ceil(watchedStats.total / 20);
  // render Prev / page number buttons / Next using watchedPage and totalPages
}
```

---

### Rendering stats

```js
function renderWatchedStats() {
  const s = watchedStats;
  if (!s) return;

  const lecturePercent = s.totalLecturesInCourses
    ? ((s.lecturesWatched / s.totalLecturesInCourses) * 100).toFixed(1)
    : 0;
  const videoPercent = s.total
    ? ((s.videosCompleted / s.total) * 100).toFixed(1)
    : 0;
  const watchHours = (s.watchTimeSeconds / 3600).toFixed(1);

  document.getElementById('stat-first-watched').textContent =
    s.firstWatchedAt ? formatDate(s.firstWatchedAt) : '—';
  document.getElementById('stat-last-watched').textContent =
    s.lastWatchedAt ? formatDate(s.lastWatchedAt) : '—';
  document.getElementById('stat-lectures').textContent =
    `${s.lecturesWatched} / ${s.totalLecturesInCourses} (${lecturePercent}%)`;
  document.getElementById('stat-courses').textContent = s.coursesEngaged;
  document.getElementById('stat-videos-completed').textContent =
    `${s.videosCompleted} / ${s.total} (${videoPercent}%)`;
  document.getElementById('stat-watch-time').textContent = `${watchHours} hrs`;
}
```

---

### Rendering video rows

Each entry in `watchedVideos` has a `VideoInfo` object that includes the lecture and course chain. A video may link to more than one lecture or course — pick the first or display all.

```js
function renderWatchedVideoRows() {
  const container = document.getElementById('watched-video-list');
  container.innerHTML = '';

  if (!watchedVideos.length) {
    container.innerHTML = '<p>No watched videos found.</p>';
    return;
  }

  watchedVideos.forEach(entry => {
    const video       = entry.VideoInfo;
    const seenMin     = Math.round((entry.seen ?? 0) / 60);
    const allocMin    = Math.round((entry.allocated ?? 0) / 60);
    const isDone      = entry.done ? '✓' : '○';

    // First lecture and course linked to this video
    const firstLink    = video.Lecture[0];
    const lectureName  = firstLink?.Lecture?.name ?? '—';
    const firstCourse  = firstLink?.Lecture?.Course[0];
    const courseName   = firstCourse?.Course?.name ?? '—';

    const row = document.createElement('div');
    row.className = 'watched-video-row';
    row.innerHTML = `
      <span class="done-badge">${isDone}</span>
      <div class="video-info">
        <strong>${lectureName}</strong>
        <span class="video-code">${video.videoCode ?? '—'}</span>
        <span class="seen-time">Seen: ${seenMin} min / ${allocMin} min</span>
        <span class="course-name">Course: ${courseName}</span>
      </div>
    `;
    container.appendChild(row);
  });
}
```

---

### Opening the panel for a user

Call this when navigating to a user's detail page or opening a watched-videos drawer:

```js
function openWatchedVideosPanel(userId) {
  watchedVideosUserId = userId;
  watchedSearch       = '';
  watchedPage         = 0;
  watchedStats        = null;
  watchedVideos       = [];
  fetchWatchedVideos();
}
```

---

### Key field paths in the response

| What to display | Path in `watchedVideos[n]` |
|-----------------|---------------------------|
| Done badge | `entry.done` |
| Seconds watched | `entry.seen` |
| Total seconds allocated | `entry.allocated` |
| Last position | `entry.lastSeen` |
| First watched date | `entry.createdAt` |
| Video code | `entry.VideoInfo.videoCode` |
| Video type / tab | `entry.VideoInfo.type`, `entry.VideoInfo.tab` |
| Lecture name | `entry.VideoInfo.Lecture[0].Lecture.name` |
| Course name | `entry.VideoInfo.Lecture[0].Lecture.Course[0].Course.name` |
| Course ID | `entry.VideoInfo.Lecture[0].Lecture.Course[0].courseId` |
