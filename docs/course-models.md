# Course Models

## Course

The central content entity. A `Course` can represent a standalone course, a session within a course, or a pathway (bundle), controlled by the `type` field. Courses are self-referential — a child course points to its parent via `courseId`.

| Field | Type | Notes |
|-------|------|-------|
| `id` | Int (PK) | Auto-increment |
| `name` | String | Display name |
| `abbr` | String? | Short code / abbreviation |
| `courseId` | Int? | FK → parent `Course.id` (self-relation) |
| `order` | Int? | Sort order among siblings |
| `type` | String? | E.g. `"course"`, `"session"`, `"pathway"` |
| `expiry` | DateTime? | Access expiry date |
| `includeParent` | Boolean? | Whether parent content is included on enrollment |
| `isActive` | Boolean? | Soft on/off toggle |

### Key relations

| Relation | Description |
|----------|-------------|
| `Course / Courses` | Self-referential parent ↔ children tree |
| `Meta` → `CourseMeta` | Logo, descriptions, price, hours, purchasable flag |
| `Options` → `CourseOption` | Arbitrary key/value config per course (e.g. `isEnrollable`, feature flags) |
| `Subjects` → `CourseSubject` (via join) | Syllabus subjects attached to this course |
| `Category` → `CourseCategory` (via join) | Which categories this course belongs to |
| `Platform` → `PlatformToCourse` | Which tenant platforms expose this course |
| `User` → `UserToCourse` | Enrollments (users enrolled in this course) |
| `Lectures` | Lecture content linked to this course |
| `Quiz` | Quizzes published under this course |
| `PracticeAttempt` | User practice sessions |
| `Template` | Email templates scoped to this course |
| `Leads / LeadSource` | Lead-gen linkage for the call-center flow |

---

## CourseCategory

A hierarchical taxonomy for organizing courses (e.g. "Competitive Exams" → "Engineering" → "JEE"). Categories are self-referential.

| Field | Type | Notes |
|-------|------|-------|
| `id` | Int (PK) | Auto-increment |
| `name` | String | Display name (e.g. "Python", "Data Science") |
| `abbr` | String? | Short code |
| `order` | Int? | Sort order |
| `type` | String? | Category variant / level hint |
| `categoryId` | Int? | FK → parent `CourseCategory.id` (self-relation) |

### Key relations

| Relation | Description |
|----------|-------------|
| `Category / Categories` | Self-referential parent ↔ children tree |
| `Courses` → `CourseCategoryToCourse` | Courses tagged with this category |

---

## Supporting models

### CourseMeta
One-to-many with `Course`. Stores display and commerce metadata.

| Field | Notes |
|-------|-------|
| `courseLogo` | Image URL |
| `longDescription` | Rich-text JSON |
| `shortDescription` | Plain string |
| `price` | Decimal |
| `purchasable` | Whether the course can be bought directly |
| `hours` | Total content hours |

### CourseOption
Arbitrary key/value store per course (`type` + `key` + `valueJson`/`valueText`). Used for feature flags, enrollment rules, display settings.

### CourseSubject
Syllabus subjects — also self-referential (parent/child). Attached to courses via `CourseSubjectToCourse` join. Users can be individually enrolled to specific subjects within a course (`UserToCourseSubject`).

### CourseSubjectGroup
Named groups of subjects (e.g. "Electives — pick 2"), with a `count` cap, self-referential for nested groups.

### CourseCategoryToCourse
Join table linking a `Course` to one or more `CourseCategory` entries.
Composite PK: `(courseId, categoryId)`.

### UserToCourse (enrollment)
Records a user's enrollment in a course.

| Field | Notes |
|-------|-------|
| `userId` / `courseId` | The enrollment pair |
| `expiry` | Access end date |
| `instituteId` | Optional institution affiliation |
| `deviceType` | JSON — device info at enrollment |
| `EnrolledSubjects` | Specific subjects the user is enrolled in |
| `Payments` | Payment records for this enrollment |

### CourseUserMeta
Per-user, per-course metadata (completion status, external enrollment ID).

### PlatformToCourse
Maps which tenant platforms a course is published to.
Composite PK: `(platformId, courseId)`.

### CourseTemplate
Email templates (Brevo) scoped to a course + platform combination.

---

## Hierarchy summary

```
CourseCategory (tree)
    └── CourseCategoryToCourse ──► Course (tree)
                                       ├── CourseMeta       (display / pricing)
                                       ├── CourseOption     (key-value config)
                                       ├── CourseSubject    (syllabus, tree)
                                       │       └── CourseSubjectGroup
                                       ├── UserToCourse     (enrollments)
                                       │       └── UserToCourseSubject
                                       └── PlatformToCourse (tenant visibility)
```