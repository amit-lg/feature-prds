# Quiz performance — where we got to, 1 Aug 2026

Short version: `/api/quiz` was slow because of one missing index, that is fixed and
live, and the box now handles roughly 29x the load we need for the event at 2.3x the
latency. Tonight's work was mostly about being able to see what is happening — the
logging had been left in full debugging mode and was drowning out everything useful.

Nothing below is a guess unless it says so.

## What was actually wrong

`getUserQuizOverlay` was 79% of the `/api/quiz` response time, and 69% of that was a
single grouped `COUNT` against `UserQuizAnswer`. That table has 640,010 rows and had
no index other than its primary key. Neither did `UserQuizAttempt` (9,145 rows).
Postgres does not index foreign keys automatically and nobody had added them.

Adding the two indexes took that query from **107.355ms to 0.162ms**, with buffers
read dropping from 7,976 to 10. Under real load it settles around 16.3ms, which is
just the general query floor on this box rather than anything specific to the query.

Worth recording because it came up: raising `shared_buffers` would **not** have fixed
this. With 4GB of buffers and no index the same query still took 119.555ms with every
single page served from cache. It was burning CPU filtering `questionId = ANY(...)`
across 90 values, not waiting on disk.

## What is live on production now

- Indexes on `UserQuizAnswer(attemptId, questionId)` and `UserQuizAttempt(userId)`,
  applied through migration `20260801211500_quiz_overlay_indexes`, verified present.
- `shared_buffers` 128MB → 4GB
- `effective_cache_size` 4GB → 16GB
- `idle_in_transaction_session_timeout` 0 → 60s

## Capacity, measured

362 requests/sec sustained, `/api/quiz` at 58.9ms median and 496ms worst case measured
server-side, event loop lag flat at 0.0ms throughout. The event needs roughly 148
req/s. So we have headroom, on the HTTP path.

## The timeouts were not us

Load tests kept plateauing with connection timeouts and it looked like the app giving
up. It was not. Raw TCP handshake tests from the test machine:

- to the DB host, port 22 — 500 of 500 succeeded
- to cloudflare.com:443 — 500 of 500 succeeded
- to quiz.vgx.guru:443 — **174 succeeded, 326 timed out**

Kernel counters on the app server were byte-identical before and after, so those SYNs
never arrived. The app host's provider is capping inbound connections at around 174
per source IP. This will not affect 3,500 students arriving from 3,500 different
addresses, but it does mean any load test from a single machine hits a ceiling that
has nothing to do with our code. Worth knowing before someone re-runs one and panics.

## Tonight: the logging

The file logger only had info, warn and error. The step-by-step debugging
instrumentation that had been switched on was therefore writing at exactly the same
level as the logging we actually want, and there was no way to turn one off without
losing the other.

A real 171-second window produced **112,534 lines and 26MB** — 659 lines a second,
around 578MB an hour. Of that, the HTTP request log, which is the genuinely useful
part, was 3%. QuizService method tracing was 78,580 lines and every-Prisma-query
logging another 27,296.

There is now a `debug` level with a `logLevel` floor, defaulting to `info`, and the
firehose has been moved onto it. Replaying that same window under the new defaults
keeps 3,792 lines instead of 112,534 — and surfaces 80 slow queries that were
previously buried in the noise, because queries over the slow threshold now log at
`warn` instead of blending in.

Untouched, still on by default: HTTP requests, socket connect and disconnect, resource
samples, quiz cache stats. Nothing useful was lost.

To get the detail back when debugging:

    logLevel=debug                              # Prisma queries, pool acquires
    logLevel=debug logMethodTrace=QuizService   # plus full method tracing

Method tracing needs its own switch because on its own it peaked at 15,523 lines a
second. When it is off the methods are left unwrapped entirely, so there is no
per-call cost, not just a suppressed write.

The writer is also hardened now. `meta` is spread from arbitrary call sites, so one
circular reference or BigInt would have thrown inside whatever request happened to be
logging, and a stream error had no listener, which crashes Node. Both are handled, and
tested against circular refs, BigInt, throwing getters, throwing `toJSON`, and writes
landing after shutdown. None of them throw now.

## Tonight: sockets

We now log **why** a socket closed, and we log rejected handshakes.

That matters because of what the existing logs showed. In one 23-minute window there
were 623 connects from 75 identified users. That reads like each user opening five
sockets, but it is not — 69% of users held exactly one socket at a time. It is
reconnect churn: median gap between a user's disconnect and their next connect was
**1.6 seconds**, 42% were back inside a second, and 14% of sockets died within five
seconds of opening. 35% of disconnects carried no user ID at all, meaning those
sockets died before they ever authenticated.

We could not tell why, because the disconnect reason was never captured. It is now.

Likely cause, and this is inference rather than something proven: every rejection
branch in the socket handshake disconnects the client, socket.io reconnects it about a
second later, and it fails the same check again. Anything that cannot satisfy the
device gate loops forever. Somebody should confirm whether `isDevice` is switched on
for the platform in question — I could not check that from here.

Also worth flagging: peak was 103 concurrent sockets with event loop lag at 20.9ms and
RSS between 320 and 511MB. Nothing was straining at that scale.

## Tonight: handshake cost

The socket handshake was resolving the platform and its `isDevice` flag straight from
the database on every single connect, while the HTTP path has had both cached all
along. Combined with the reconnect churn above, that means a client stuck in a loop
was paying two queries per attempt, and everybody coming back after a restart paid two
queries each on the way in. A herd of 3,500 was about 7,000 queries.

Both are cached now. After the first client, everyone else is served from Redis.

The trade, which is the same one the permission middlewares already accept: toggling
`isDevice`, or editing platform config, now takes up to five minutes to reach socket
handshakes. There is no write-through invalidation.

## Where the code is

Two commits on `Redis-Cache`. They were pushed at 04:03 on 2 Aug, just after this
was written, but that did not deploy them — the production container still runs
an image built from `origin/main` (`38e7aa0a`), which predates both:

    c9bcc1b3  fix(logging): add a debug level, and make logs unable to crash a request
    ead02a33  perf(socket): cache the platform lookups in the WebSocket handshake

They typecheck and the logger's failure modes are unit-tested, but neither has run
against a live app yet. That needs a deploy before we trust them.

## The one thing that genuinely worries me

**The WebSocket quiz-taking path has never been load tested.** Everything measured
above is HTTP. Actually taking a quiz runs over sockets, across 98 message handlers,
and not one of them has ever been exercised under load or logs anything. That is the
real event path and it is a blind spot.

Building a socket harness is the next job.

## Also open, not urgent tonight

Autovacuum has never run on the five largest tables — `UserPracticeAnswer` alone is
carrying 295,000 dead rows. There are 5.6 repeated `User` lookups per request. 24
tables have nothing but a primary key, and the lead tables are in worse shape than the
quiz ones. Separately, and not for this week: Postgres 10.23 is end-of-life, `ssl` is
off so traffic crosses the internet in cleartext, there is a single `postgres`
superuser, and there is no archiving or point-in-time recovery.
