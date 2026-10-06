# Job Chatroom — Design Document

## Overview

This document describes the chatroom feature built around the job-posting flow. A chatroom is created when a job seeker applies to a job, connecting the seeker with the recruiter for that specific job.

---

## Actors

| Actor | Identity |
|---|---|
| Job Seeker | Platform user (`User`) |
| Recruiter | Platform user (`User`) — the one who posted the job |

Both sides are plain `User` records. The chatroom is a **User ↔ User** relationship keyed on the job ID.

---

## Flow

```
Recruiter posts a job
        │
Job Seeker applies to the job
        │
A new Chatroom is created between the seeker and the recruiter for that job
        │
Recruiter sends the first message
        │
Both parties exchange messages in real time
```

---

## Chatroom States

| State | Description | Who can send |
|---|---|---|
| `PENDING` | Created on application; recruiter has not messaged yet | Recruiter only |
| `ACTIVE` | Recruiter has sent the first message | Both parties |
| `READ_ONLY` | Job is closed, filled, or deleted | Nobody |

State transitions:

```
PENDING ──(recruiter sends first message)──► ACTIVE
ACTIVE  ──(job closed / filled / deleted)──► READ_ONLY
PENDING ──(job closed / filled / deleted)──► READ_ONLY
```

### Enforcing Recruiter-First

Before inserting a message, the service checks:

1. If `chatroom.state === 'PENDING'` and `message.senderId !== chatroom.recruiterUserId` → reject with `403 RECRUITER_MUST_MESSAGE_FIRST`.
2. If `chatroom.state === 'READ_ONLY'` → reject with `403 CHATROOM_READ_ONLY`.
3. On the first successful recruiter message: transition `state` from `PENDING` to `ACTIVE` in the same transaction as the message insert.

---

## Edge Cases

| # | Scenario | Handling |
|---|---|---|
| 1 | Seeker tries to message before recruiter | `403 RECRUITER_MUST_MESSAGE_FIRST`; no message persisted |
| 2 | Recruiter tries to message on a `READ_ONLY` chatroom | `403 CHATROOM_READ_ONLY` |
| 3 | Job is deleted while chat is `PENDING` | Chatroom transitions to `READ_ONLY` before first message |
| 4 | Recruiter and seeker are the same `User.id` | Reject at chatroom creation — a user cannot be both parties |
| 5 | Message sent to a chatroom the requesting user is not a member of | Verify sender is either the seeker or the recruiter of that chatroom; reject `403` otherwise |
| 6 | Many applicants for a popular job | Each application gets its own chatroom — recruiter's list can grow large; pagination and filtering by job are required |
| 7 | Platform isolation | A user on one platform cannot access chatrooms belonging to another platform |
