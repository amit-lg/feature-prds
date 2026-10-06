# Runbook — WebSocket quiz load test

For whoever is running this. You should not need to have been in any prior
conversation. Everything below is either verified against the code (file and
line given) or explicitly marked as unknown.

## What this tests, and why it is the gap

A 3,500-student quiz event is coming. All capacity work so far has been on the
HTTP path — `GET /api/quiz` and friends. But **actually taking a quiz runs over
Socket.IO**, across handlers that have never been load tested and that log
nothing. That is the blind spot this closes.

There are 98 `@SubscribeMessage` handlers in the app. The quiz-taking path is
five of them.

## Status — read this before anything else

**You are the first person to execute this harness.** It has been verified
against the source but never run: syntax checked, `socket.io-client` confirmed
present, and all five request/reply event pairs read directly out of
`quiz.service.ts`, `auth.service.ts` and `user.gateway.ts`. That static check
already caught one real bug before it cost anyone a run.

What that means practically: the code is sound, but the one thing that could not
be verified without a live server is the **shape of the `give-quiz-questions
-success` payload**. The harness pulls questions out of it defensively and says
so loudly if it cannot. This is the expected place for a first-run failure, and
"If something fails" below tells you exactly what to do about it.

Everything else is done and needs no decisions from you:

| done | where |
|---|---|
| the harness itself | `loadtest/socket-quiz.js` |
| throwaway quiz creation | `loadtest/create-test-quiz.js` |
| the event contract (which reply follows which emit) | verified, tabulated in step 3 |
| the per-source-IP connection limit characterised | measured, tabulated in step 5 |
| results format + gitignore | `out-socket-*.json` |

### Getting the code

These scripts live on the **`Redis-Cache`** branch, in these commits:

    fc6d627c  test(loadtest): add a socket quiz harness that actually takes the quiz
    0fe1fb2a  docs(loadtest): add the socket load test runbook for handover

Then `npm install` at the repo root — the harness uses the repo's own
`socket.io-client` and adds no new dependency.

If those commits are not on the remote when you look, ask for them to be pushed.
They were deliberately not pushed at the time of writing, because pushing a
branch here can trigger a Coolify auto-deploy and that is not a decision the
person writing this runbook should be making unilaterally.

## Before you start, you need

| thing | why | if you don't have it |
|---|---|---|
| this repo, `npm install` done | the harness uses the repo's `socket.io-client` | — |
| `loadtest/users.csv` | user JWTs to connect with | regenerate — see step 1 |
| an **employee** JWT (`path: 'command'`) | creating the test quiz is admin-only | log into the admin UI for the platform, copy the bearer token from devtools |
| several machines with different public IPs | the provider rate-limits connections from any single address, so one machine cannot generate event-scale load — see step 5 | you can still do step 4, but you cannot reach event scale |

`TARGET` and `PLATFORM_ORIGIN` are already in `loadtest/.env.staging` and every
script loads that file automatically.

**`users.csv` holds live JWTs for real user accounts.** It is gitignored and
dockerignored. Never commit it, never let it into an image, delete it after the
event.

## Step 1 — tokens

Check the existing ones still work before regenerating:

    curl -s -o /dev/null -w '%{http_code}\n' \
      -H "Authorization: Bearer <token from users.csv>" \
      -H "origin: $PLATFORM_ORIGIN" \
      "$TARGET/api/quiz"

`200` means you are fine. `401` means they expired — regenerate with
`node loadtest/login-tokens.js`, which needs only `TARGET`, `PLATFORM_ORIGIN`
and a `loadtest/accounts.csv` of `email,password` lines. No database, no
`jwtSecret`, no Redis.



Note the trade documented in that script: you get one distinct user per account
supplied, and the quiz structure cache is keyed per user, so a handful of
accounts gives a permanently warm cache and optimistic latency.

## Step 2 — create a throwaway quiz

**Do not point this at a real quiz.** The harness creates genuine attempt and
answer rows for real user accounts. A student who later opens that quiz finds an
in-progress attempt with random answers already filled in and a running clock.

    DRY_RUN=1 node loadtest/create-test-quiz.js                                  # see the plan
    EMPLOYEE_TOKEN=<jwt> CONFIRM_WRITES=yes node loadtest/create-test-quiz.js

It prints the new quiz id. Keep it — everything downstream needs it as
`QUIZ_ID`.

The quiz shape is deliberate, chosen against the gates in
`QuizService.startQuiz`:

| choice | why |
|---|---|
| `accessType: 'free'` | the enrolment check (`quiz.service.ts:2750`) only runs for `paid`/`registered`/`registered-group`. Free means **no user needs a `quizToUser` row** |
| `attemptType: 'repeat'` | `:2812` deletes the previous attempt and creates a fresh one, so reruns are clean. Under `'single'` every user is rejected on their second run with *"You have already attempted this quiz"* |
| no `startTime`/`endTime` | skips the *"Quiz not started yet"* and *"Quiz ended"* gates |
| no `leadQuiz`/`mockQuiz` option | `sendQuizDataToSheet` returns early at `:5646`. With either option set it POSTs each student's **name, email and phone** to an external Google Apps Script URL |

Existing quizzes are mostly unusable anyway — at the time of writing three of the
four visible on platform 7 fail the `endTime < now` gate, and the fourth is
`registered` with nobody enrolled.

## Step 3 — smoke test, one socket

Always do this before scaling. It proves the whole chain and dumps the payload
shape.

    QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=1 DEBUG_PAYLOAD=1 \
      node loadtest/socket-quiz.js

Expect `reached quiz 1` and a non-zero answer count. If `reached quiz` is 0, read
the `errors` block — every failure is named and counted, with the server's own
message.

The sequence it walks, and the reply it waits for at each step:

| emit | success | error |
|---|---|---|
| `login` `{token}` | `login-success` | `login-error` |
| `make-quiz-attempt` `{quizId}` | `make-quiz-attempt-success` | `make-quiz-attempt-error` |
| `give-quiz-questions` | `give-quiz-questions-success` | `give-quiz-questions-error` |
| `watch-quiz-question` `{questionId}` | `watch-quiz-question-success` | `watch-quiz-question-error` |
| `add-option-quiz-question` `{optionId}` | `add-option-quiz-question-success` | `add-option-quiz-question-error` |

The order is not optional. All of this state lives on the server's socket object,
and `add-option-quiz-question` rejects unless `userId` **and** `attemptId` **and**
`questionId` are all set (`user.gateway.ts:562`).

## Step 4 — single machine ladder

Raise `SOCKETS` a rung at a time, holding each for a few minutes:

    QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=50  DURATION_SEC=300 node loadtest/socket-quiz.js
    QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=100 DURATION_SEC=300 node loadtest/socket-quiz.js
    QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=150 DURATION_SEC=300 node loadtest/socket-quiz.js

Stop at **150 per machine**. Above that you stop measuring the app — see below.

Each run writes `loadtest/out-socket-<stamp>.json`, already gitignored.

### Every setting the harness takes

| env | default | what it does |
|---|---|---|
| `QUIZ_ID` | — | the quiz to take. Required (or `QUIZ_SLUG`) |
| `CONFIRM_WRITES` | — | must be `yes`. The harness writes real rows and refuses to start without it |
| `SOCKETS` | 50 | concurrent sockets held open. Keep ≤150 per source IP |
| `RAMP_PER_SEC` | 10 | new connections per second while ramping up |
| `DURATION_SEC` | 120 | how long to hold sockets after the ramp finishes |
| `ANSWER_EVERY_MS` | 8000 | pause between answers per socket, jittered ±25% so they do not all fire on the same tick |
| `STEP_TIMEOUT_MS` | 20000 | how long to wait for any single reply before calling it a timeout |
| `RECONNECT` | off | `1` allows socket.io reconnects. Off by default so failures surface instead of being papered over — leave it off unless you are specifically testing reconnect behaviour |
| `DEBUG_PAYLOAD` | off | `1` dumps the first `give-quiz-questions` payload to `loadtest/give-quiz-questions-payload.json` |
| `SHARD_COUNT` | 1 | how many machines are running. See step 5 — mandatory for multi-machine runs |
| `SHARD_INDEX` | 0 | this machine's 0-based slice of `users.csv` |
| `TARGET_WS` / `TARGET` | from `.env.staging` | base url |
| `PLATFORM_ORIGIN` | from `.env.staging` | sent as the `origin` header. Platform resolution fails without it |

`create-test-quiz.js` takes `EMPLOYEE_TOKEN`, `CONFIRM_WRITES`, `PLATFORM_ID`
(default 7), `QUESTIONS` (default 10), `OPTIONS_PER_Q` (default 4) and
`DRY_RUN=1`.

## Step 5 — several IPs, the real run

You need several source IPs because **the provider rate-limits connections
coming from a single address**. This is a limit on the test rig's side of the
wire, not a limit on how many sockets the server can hold — the server's socket
capacity is exactly what you are here to measure, and it is untested.

Measured, raw TCP handshakes, no TLS and no requests:

| source | target | result |
|---|---|---|
| test VPS | `quiz.vgx.guru:443` | 174 of 500 ok, 326 timeout |
| a different machine | `quiz.vgx.guru:443` | 203 of 500 ok, 297 timeout |
| that same machine | `vps.vgx.me:443` (control) | **500 of 500 ok** |
| that same machine | `quiz.vgx.guru:443`, 150 at once | 150 of 150 ok, twice |

The control matters: the same machine that plateaus at ~200 against the quiz
host opens 500 elsewhere, so nothing is wrong with the test machine. And 174 and
203 not being the same number, plus 150 connections taking 8.6s to establish
against 4.9s for 500 to an unthrottled host, says this is **rate shaping rather
than a fixed ceiling**.

**This does not affect the event.** 3,500 students arrive on 3,500 different
addresses, and the limit is per address. It constrains only how much load one
test machine can generate — which is precisely why the run is distributed.

So budget **≤150 sockets per source address** and add machines to go higher.
3,500 sockets is roughly 24 machines at that rate.

### Split users.csv across the machines — this is mandatory

**Every machine must run a different slice of `users.csv`.** Do not copy the same
file to every box and let them all take the first 150 users.

This is a correctness requirement, not tidiness. One socket per user is enforced.
If the same token runs on two sockets — whether on one machine or across two —
that user starts the quiz twice, and on a `repeat` quiz the second start
**deletes the first attempt** (`quiz.service.ts:2817`). The earlier socket then
answers into rows that no longer exist. The run reports healthy and measures
nothing.

The harness shards for you. Give each machine its index:

    # 3 machines, same users.csv on each
    SHARD_COUNT=3 SHARD_INDEX=0  QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=59 node loadtest/socket-quiz.js
    SHARD_COUNT=3 SHARD_INDEX=1  QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=59 node loadtest/socket-quiz.js
    SHARD_COUNT=3 SHARD_INDEX=2  QUIZ_ID=<id> CONFIRM_WRITES=yes SOCKETS=59 node loadtest/socket-quiz.js

Slices are contiguous and non-overlapping, with any remainder going to the last
machine. The harness **refuses to start** if `SOCKETS` exceeds the users
available in its shard, rather than silently reusing tokens.

### The user pool is your real ceiling

`users.csv` currently holds **177 users**. One socket per user means 177 users
buys you 177 sockets — total, across every machine. Adding machines does not
change that; it only spreads the same users thinner:

| machines | users each | max sockets each | total sockets |
|---|---|---|---|
| 1 | 177 | 177 | 177 |
| 3 | 59 | 59 | 177 |
| 24 | 7 | 7 | 177 |

So there are two separate limits and you need both solved to reach event scale:

- **≤150 sockets per source IP** → needs more machines
- **one socket per user** → needs more users

For 3,500 sockets you need roughly 3,500 tokens *and* ~24 machines.
`loadtest/mint-tokens.js` builds a cohort that size (`--count 3500`), but it
needs `DATABASE_URL` and `jwtSecret` for the environment.
`loadtest/login-tokens.js` needs neither, but yields only one user per account
you supply.

Until the pool grows, 177 sockets is the honest maximum. Still worth running at
that scale — it proves the chain end to end, produces real per-handler latency,
and surfaces anything that breaks before the cohort is built. It just will not
tell you what happens at 3,500.

## Reading the results

Per event you get n / p50 / p90 / p95 / p99 / max, plus counters, a named error
tally, and client-side disconnect reasons.

Look for, in order:

1. **Errors at all.** A working run has an empty error block. Anything in it is
   the finding.
2. **`add-option-quiz-question` latency.** This is the write path and the one
   3,500 students hammer repeatedly. It is where a knee will show first.
3. **The curve between rungs.** Latency roughly flat from 50 to 150 sockets means
   headroom. A step change means you found the knee — record the socket count.
4. **Disconnect reasons.** Anything other than the harness's own `io client
   disconnect` at shutdown is worth chasing.

When aggregating across machines: **sum the counters, but do not average the
percentiles** — percentiles do not combine that way. Report the worst p95 seen
and the spread across machines.

## Traps — each of these costs a wasted run

- **`watching-question` is not the reply to `watch-quiz-question`.** It is a
  group room broadcast (`quiz.service.ts:3699`) that only fires when a group room
  exists. The harness waits on `watch-quiz-question-success`, correctly. Do not
  "fix" this.
- **`quiz-start-socket.yml` does not work for this.** Artillery's socketio engine
  emits fire-and-forget: no handler latency is measured, a run where every login
  failed still reports green, and it never answers a question. Kept only for
  reference.
- **Both scripts refuse to run without `CONFIRM_WRITES=yes`.** That is on purpose;
  they write to the database.
- **Do not run `npm run build` against a production `DATABASE_URL`.** It runs
  `prisma migrate deploy` first.
- **Pushing this repo's branches can trigger a Coolify auto-deploy.** Do not push
  without saying so first.

## If something fails

Every failed step is a named, counted error carrying the server's own message,
so the `errors` block in the output tells you which of these you have.

| what you see | what it means | what to do |
|---|---|---|
| `login: Invalid Token` | the JWTs in `users.csv` have expired | regenerate, step 1 |
| `give-quiz-questions: no questions found in payload` | the payload shape differs from what the extractor expects | rerun with `DEBUG_PAYLOAD=1`, then send `loadtest/give-quiz-questions-payload.json` on — this is the known first-run risk and it is a five-minute fix |
| `make-quiz-attempt: You are not enrolled for this quiz.` | the quiz is not `accessType: 'free'` | you are pointing at the wrong quiz — use the one `create-test-quiz.js` made |
| `make-quiz-attempt: Quiz ended` / `Quiz not started yet` | the quiz has a time window | same — wrong quiz |
| `make-quiz-attempt: You have already attempted this quiz` | the quiz is `attemptType: 'single'` | same. The throwaway quiz is `'repeat'` precisely to avoid this |
| `connect: ...` failures or a plateau in `connected` | you are hitting the inbound throttle | lower `SOCKETS` to ≤150 and add machines |
| `TIMEOUT after 20000ms` on a quiz step | the server did not reply in time | **this is a finding, not a harness bug.** Record the socket count it started at |

A run where `connected` is high but `reached quiz` is 0 is an auth or quiz
problem, not a capacity one. A run where both are high and errors appear only at
higher rungs is what you are actually looking for.

## What to report back

Send these four things. Nothing else is needed.

1. **The `out-socket-*.json` files**, one per machine per rung.
2. **The peak concurrent socket count the server sustained**, and whether it was
   still healthy there. This is the number the whole exercise exists to produce —
   the event needs 3,500 and nothing has ever measured what the socket path can
   actually hold. State it plainly; it is easy to lose in a pile of latency
   percentiles.
3. **The knee**, if you found one: the socket count at which latency stepped up
   or errors began, and which event degraded first.
4. **Anything in the errors block** that is not in the table above.

## Analysing the results with Claude

You can hand the whole analysis to a Claude session. Open one in the repo, make
sure the run outputs are on the same machine, and paste the prompt below
verbatim. It is written to be self-contained — it does not assume Claude knows
anything about this project.

If you also have SSH to the app host, collect the app's own logs first, because
they are the other half of the picture:

    # container name, then its logs
    docker ps --format '{{.Names}}'
    docker logs <container> --since 2h > app-docker.log 2>&1

    # the app also writes structured JSON logs inside the container
    docker exec <container> ls -la /app/logs
    docker cp <container>:/app/logs ./app-logs

Those files are on **ephemeral container disk with no volume mounted**, so they
are lost on every redeploy. Copy them out before anything restarts.

There is also an existing analyser in the repo, `loadtest/analyze-logs.js`, which
does percentiles, peak in-flight and latency-vs-concurrency. Claude should use it
rather than reinventing it.

---

```
I ran a WebSocket load test against a NestJS quiz application and need you to
interpret the results. Assume I have not told you anything else about this
system.

WHAT THE TEST DID
Each simulated student opened a Socket.IO connection to the /user namespace and
walked this exact sequence, waiting for each reply before sending the next:
  login -> make-quiz-attempt -> give-quiz-questions -> then repeatedly
  watch-quiz-question -> add-option-quiz-question   (answering questions)
Sockets were held open for the whole run rather than reconnecting. Each step was
timed individually.

THE FILES
- loadtest/out-socket-*.json  : one per machine per rung. Contains config,
  counters (connected, connectFailed, completedSetup, answers), per-event
  latency percentiles, an error tally, and client-side disconnect reasons.
- app-docker.log / app-logs/  : the server's own logs, if I collected them.
  The app writes newline-delimited JSON with time, level, context, message.
- loadtest/analyze-logs.js    : an existing analyser in this repo. Use it
  instead of writing your own percentile code.

WHAT I NEED FROM YOU

1. Whether the run is valid at all. If `connected` is high but `completedSetup`
   is 0, it is an auth or configuration failure, not a capacity result, and
   every latency number in it is meaningless. Say so before anything else.

2. The knee. Compare rungs and tell me the socket count at which latency stepped
   up or errors began, and which event degraded first. I care most about
   add-option-quiz-question, because that is the write path that 3,500 students
   will hammer repeatedly during a live event. If latency is flat across all
   rungs, say that plainly - it means the knee is above what was tested.

3. Aggregation across machines. Sum the counters. Do NOT average the
   percentiles - percentiles do not combine that way. Report the worst p95 seen
   and the spread between machines.

4. Correlate with the server logs, if present. For each latency spike in the
   harness output, tell me what the app was doing at that timestamp: slow
   queries (these log at warn), connection pool acquire delays, errors, or
   nothing at all. "Nothing in the logs" is itself a finding - it means the app
   did not consider itself slow.

5. Disconnect reasons. Anything other than a clean client-initiated disconnect
   at shutdown is worth chasing. Group them and tell me which sockets they
   happened to.

6. Flag anything that suggests a bottleneck OUTSIDE the app: connection refusals
   or timeouts at a consistent count (a network or provider limit rather than a
   software one), latency that rises with wall-clock time rather than with load
   (a leak or accumulating state), or DB-shaped stalls.

HOW TO ANSWER
Label every claim as MEASURED (it is in the data) or INFERRED (it is your
reading of the data). Never state an inference in the same voice as a
measurement. If the data does not support a conclusion, say what additional
measurement would settle it rather than guessing. Be concrete: quote the actual
numbers and file names you are drawing from.
```

---

## Cleanup

Not yet written. With `attemptType: 'repeat'` the attempts are largely
self-cleaning — each new `make-quiz-attempt` deletes the prior attempt — so the
footprint stays at roughly one attempt plus one answer row per question per user,
on the throwaway quiz only.

If you want it gone entirely, delete the attempts for that quiz id and then the
quiz itself. Check the schema's cascade rules first so the delete order is right.

## Worth measuring while you are in here

`startQuiz` calls `sendQuizDataToSheet` on **every** attempt creation
(`quiz.service.ts:3020`), un-awaited. It runs a three-level nested
`Questions → Questions → Questions` query and POSTs to an external Google Apps
Script endpoint. Because nothing waits for it, it never appears in response time
— but 3,500 students starting at once means 3,500 deep queries plus 3,500
outbound calls in the event's worst moment. Nobody has measured it.

It is skipped entirely for the throwaway quiz (no `leadQuiz`/`mockQuiz` option),
so your load test will not exercise it. **Check whether the real event quiz has
one of those options set.** If it does, that path is live during the event.
