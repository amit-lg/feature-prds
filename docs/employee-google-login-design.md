# Employee Google Login — Design

## Goal

Let an employee sign in to Command with their Google account, in addition to
the existing email/password login, without changing anything downstream of
login (JWT shape, `EmployeeAuthGuard`, socket presence flow all stay
identical).

If a Google account's email matches an existing `Employee.email`, Google
sign-in just links to that row. If it doesn't match anything, we
**auto-provision a new `Employee`** from the Google profile (`given_name`,
`family_name`, `email`, `picture`), with a random, unusable password —
the same pattern `EmployeeService.addEmployee` already uses today
(`password: uuidv4()`, `src/employee/employee.service.ts:989`) for
admin-created employees. That row then only ever authenticates via Google
going forward (nobody knows the random password).

## Current login flow (unchanged, for reference)

1. `POST /command/login` — `CommandLoginDto { email, password, deviceId }`.
2. `AuthService.employeeLogin` (`src/auth/auth.service.ts:755`):
   - Finds `Employee` by email, compares `password`.
   - Checks the device is registered and allowed
     (`EmployeeDevices` / `EmployeeToDevice`).
   - Calls `giveEmployees(employeeId, platformId, deviceId)`.
3. `giveEmployees` signs a JWT (`{ employeeId, platformId, deviceId, path:
   'command' }`), stores a row in `EmployeeRefreshToken`, and returns
   `{ accessToken, refreshToken, employee }`.
4. `EmployeeAuthGuard` verifies that JWT on every subsequent request.
5. The employee's socket then emits a separate `login` event
   (`employee.gateway.ts` / `employee.service.ts`) to go online — attendance
   check-in, permission rooms, chat rooms. This step is unaffected by this
   change; it only cares that a valid JWT already exists.

## New flow: Google login

### 1. Frontend ↔ Google (backend not involved)

The employee-facing app renders a Google Sign-In button configured with this
platform's Google **Client ID**. Google authenticates the user directly in
the browser and hands back a signed **ID token** (JWT) — never a
password, never anything the frontend can forge.

### 2. Frontend → backend

The frontend POSTs that ID token to a new endpoint:

```
POST /command/login/google
Body: { credential: string, deviceId: string }
```

`credential` is the raw Google ID token. `deviceId` matches the existing
`CommandLoginDto.deviceId` semantics — the device-allowlist check is
identical to password login.

### 3. Backend verification (the part that actually matters)

```ts
const ticket = await oauthClient.verifyIdToken({
  idToken: dto.credential,
  audience: process.env.googleClientId, // ours, never taken from the request
});
const payload = ticket.getPayload(); // { sub, email, name, exp, ... }
```

This call:
- Checks the JWT's signature against Google's public keys (proves Google
  issued it, not the frontend).
- Checks `aud` equals our own `googleClientId` (proves the token was issued
  for this app, not replayed from a different one).
- Checks `exp` (expiry) — see **Expired/invalid token handling** below.

If verification fails for any reason, the login is rejected before any
database lookup happens.

### 4. Resolve the employee — link table

New model, `EmployeeGoogleAccount`:

```prisma
model EmployeeGoogleAccount {
  id              Int      @id @default(autoincrement())
  employeeId      Int      @unique   // one Google account per employee
  googleId        String   @unique   // Google's "sub" claim — permanent, stable
  email           String             // Google email at time of link (audit)
  googleClientId  String             // the "aud" this login/link was issued for
  createdAt       DateTime @default(now())
  lastLoginAt     DateTime @default(now())
  Employee        Employee @relation(fields: [employeeId], references: [id])
}
```

Add the inverse relation on `Employee`:
```prisma
model Employee {
  ...
  GoogleAccount EmployeeGoogleAccount?
}
```

`googleClientId` is stored (not just used transiently) because GrowthCommand
is multi-platform — different platforms could plausibly register their own
Google OAuth client in the future. Recording which client ID a link was
established under gives us an audit trail and a place to add a
per-platform check later without a migration.

Resolution logic in `AuthService.employeeGoogleLogin`:

```
1. Look up EmployeeGoogleAccount by googleId (payload.sub).
   - Found -> use its employeeId. Bump lastLoginAt.
2. Not found -> look up Employee by email = payload.email.
   - Found -> create the EmployeeGoogleAccount row linking them
     (first-time Google login for an existing employee).
   - Not found -> create a new Employee from the Google profile:
       fname:    payload.given_name (fallback: split payload.name)
       lname:    payload.family_name (fallback: split payload.name)
       email:    payload.email
       profile:  payload.picture
       password: uuidv4()   // random, never given to anyone — same
                             // convention as EmployeeService.addEmployee
     then create the EmployeeGoogleAccount row linking to the new
     employee. isActive is left at its schema default; someone with
     permission still has to grant permissions/groups/device access
     before this employee can do anything useful in Command.
```

### 5. Device check + token issuance (fully reused)

The device-allowlist block in `employeeLogin` (lines ~767-798 of
`auth.service.ts`) is extracted into a small shared private method,
e.g. `assertDeviceAllowed(employeeId, platformId, deviceId)`, used by both
`employeeLogin` and the new `employeeGoogleLogin`. Same logic today,
just no longer duplicated.

Once the employee is resolved and the device is allowed,
`employeeGoogleLogin` calls the **existing** `giveEmployees(employeeId,
platformId, deviceId)` — identical JWT shape, identical
`EmployeeRefreshToken` row, identical response shape. Nothing downstream
needs to know whether the login came from a password or from Google.

For a brand-new, auto-provisioned employee, this device check behaves
exactly like it already does for password login on an unrecognized device:
`employeeLogin` creates a disallowed `EmployeeToDevice` row and rejects the
login until an admin explicitly allows that device. So a first-time Google
sign-in from someone with no prior `Employee` row still can't get straight
into Command — it creates the employee, but device approval (and any
permission/group assignment) is still a separate admin step, same as it is
today.

## Expired / invalid token handling ("tell them to relogin")

There are two distinct places a token can expire, and they need distinct,
actionable responses instead of a generic 401.

### A. The Google ID token expires (at `/command/login/google`)

Google ID tokens are short-lived (~1 hour) and are only meant to be used
once, immediately after sign-in. `verifyIdToken` throws when the token is
expired or otherwise invalid. Catch that specifically:

```ts
try {
  const ticket = await oauthClient.verifyIdToken({
    idToken: dto.credential,
    audience: process.env.googleClientId,
  });
  ...
} catch (err) {
  throw new UnauthorizedException({
    code: 'GOOGLE_TOKEN_EXPIRED',
    message: 'Your Google sign-in has expired. Please sign in with Google again.',
  });
}
```

Since the Google Sign-In button always fetches a *fresh* ID token when
clicked, the frontend's fix is simply: show the Google button again and let
the employee click it — there is no "refresh" for an ID token, only a new
sign-in.

### B. Our own session JWT expires (on every authenticated request)

This is the day-to-day case: an employee has been logged in for a while and
their access token (from `giveEmployees`) expires. Today
`EmployeeAuthGuard` catches *all* `jwtService.verifyAsync` failures the same
way (`UnauthorizedException('Invalid Token', error.message)`), so an
expired token and a malformed/tampered token look identical to the
frontend. Split that:

```ts
try {
  const payload = await this.jwtService.verifyAsync(token, {
    secret: process.env.jwtSecret,
  });
  ...
} catch (error) {
  if (error.name === 'TokenExpiredError') {
    throw new UnauthorizedException({
      code: 'SESSION_EXPIRED',
      message: 'Your session has expired. Please log in again.',
    });
  }
  throw new UnauthorizedException({
    code: 'INVALID_TOKEN',
    message: 'Invalid session. Please log in again.',
  });
}
```

The frontend treats `SESSION_EXPIRED` (and `INVALID_TOKEN`) as "show the
login screen again" — which now offers both the password form and the
Google button, so an employee who originally signed in with Google can
relogin with Google, and vice versa.

`EmployeeRefreshToken` rows exist today but nothing currently reads them —
there is no token-refresh endpoint, so re-authentication is the only
recovery path for an expired session either way. Wiring up silent refresh is
out of scope here; this design only makes the expiry *legible* to the
frontend.

## Summary of changes

| File | Change |
|---|---|
| `prisma/schema.prisma` | Add `EmployeeGoogleAccount` model + `Employee.GoogleAccount` relation |
| `prisma/migrations/` | New migration: `add_employee_google_account` |
| `src/command/dto/command-google-login.dto.ts` | New DTO: `{ credential: string, deviceId: string }` |
| `src/command/command.controller.ts` | New route: `POST /command/login/google` |
| `src/auth/auth.service.ts` | New method `employeeGoogleLogin` (resolve-or-create employee, `password: uuidv4()` on create); extract `assertDeviceAllowed` shared helper; expired-token handling in `employeeLogin`'s existing error paths stays as-is (out of scope) |
| `src/auth/guards/employee-auth.guard.ts` | Distinguish `TokenExpiredError` from other verification failures |
| `package.json` | Add `google-auth-library` dependency |
| `.env` | Add `googleClientId` |

## Explicitly out of scope

- Auto-granting permissions, groups, or device access to an
  auto-provisioned employee — Google login only creates the `Employee` +
  `EmployeeGoogleAccount` rows; someone still has to assign permissions and
  approve their device before they can do anything, same as any other new
  hire today.
- Silent access-token refresh via `EmployeeRefreshToken` (doesn't exist
  today for password login either; not introduced here).
- Hashing `Employee.password` (pre-existing plaintext comparison,
  unrelated to this change).
- Any use of a Google **client secret** — this flow only verifies an ID
  token, which needs no secret. A secret is only relevant if GrowthCommand
  later needs to call Google APIs (Calendar/Drive/etc.) on an employee's
  behalf via the authorization-code flow.
