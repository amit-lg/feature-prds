# Quiz timing without sockets — the plan

**Status:** backend steps 1-8 done (step 8 partial by design - see there); front-end steps 1, 3, 4,
5, 6 and 8 done (front-end step 4 with one small accompanying backend change,
`QuizService.getCurrentQuizAttemptV2` now carrying `serverTime` — see there; front-end step 1 also
had a real gap found and closed while starting step 6 - see the note there); front-end step 2 fully
done as of step 5 (the background-thread mechanism landed with steps 1/3, and step 5 gave the
check-in its own cadence-owning worker too - see step 5's note on why that is a second worker, not
the same one); front-end step 6 decided "just enable the button" (see there); backend order-of-work
step 9 partially done by explicit request, ahead of the counters/evidence gate (this branch isn't
merged/deployed yet) - every socket push mimicking a RETIRED cron is gone; `handleStartingQuizes`'s
`quiz-start` push is untouched, since that cron was kept, not retired (see there); front-end step 7
still blocked on live usage counters for that remaining push.
**Update, 8 September 2026:** `handleWhatsappReminders` is retired - the `quiz_whatsapp_reminders_enabled`
flag is gone now that the `MessageSend` migration is applied, so `src/quiz-reminder/`'s WhatsApp step
runs unconditionally and the old cron path was deleted (retirement comment where it lived in
`quiz.service.ts`). `handleQuizes()` now only runs `handleStartingQuizes`. Its `socketsJoin`/
`socketsLeave` room reassignment (waiting room → quiz room) is commented out, not deleted - nothing
listens for the `quiz-start` push any more, but the room move itself still matters for group-quiz
peer presence and the counters/evidence gate for retiring that specifically has not been cleared, so
it is disabled rather than removed. The `quiz-start` push itself is left running.
**The Start button itself is handled entirely by the frontend**, not by a backend alarm: front-end
step 6's client-side countdown (off the device clock) enables it on its own once `startTime` has
passed, and the actual gate stays server-side, on the start request itself
(`startQuizInternal`/`startQuizAttemptV2Locked` both reject an early start regardless) - so nothing
at the start moment needs the server to act on the button's behalf. This held until 8 September
2026, when the `quiz-start` **push** (a separate thing from the button) was migrated onto a BullMQ
job anyway, by request - see order-of-work step 10. It is folded into `QuizEndService`
(`src/quiz-alarms/`) rather than a queue of its own, dual-runs with the cron, and still leaves the
room-reassignment half of `handleStartingQuizes` untouched (see step 10's own entry for why).
**Scope:** the quiz module only, in `GrowthCommand` and `LMS_V2` — specifically the five behaviours
carried by two crons in [src/tasks/tasks.service.ts](../src/tasks/tasks.service.ts),
`handleQuizes()` and `sweepStaleAttemptSessions()`. Nothing beyond those five. As of step 8,
`sweepStaleAttemptSessions()` is gone and `handleQuizes()` was trimmed to the two behaviours
(`handleStartingQuizes`, `handleWhatsappReminders`) still awaiting their own replacements; as of the
8 September update above, only `handleStartingQuizes` remains - see step 8's own entry in the order
of work below for exactly what that leaves running and why.
(**Correction, 5 September 2026,** for context on earlier revisions of this doc: both crons were
briefly, incorrectly called "already disabled" here, which was true only of a local, uncommitted,
unrelated horizontal-scaling change sitting in the same working tree at the time and since removed
from it - they were live at HEAD until this step actually retired what it retires.)
**Resolves:** [docs/cron-removal.md](cron-removal.md) entries 4, 5 and 10, all currently reading *"Solution: not decided yet."*

Four guarantees — everyone on the same clock, every attempt closed when time runs out, a record of
who left, and the reminder that goes out before a quiz opens — with no live connection holding them
up and no clock scanning the database every five seconds.

---

## Where this actually stands

This is the last third of a migration, not the start of one. The move off sockets is already
largely done, and this plan is shaped by that rather than by a blank page.

| | What exists today |
|---|---|
| **Done** | **A full request-and-response API for taking a quiz.** Start, resume, read questions, watch a question, answer, submit, pause and check in all have plain endpoints. Documented in [docs/quiz-practice-http-api.md](quiz-practice-http-api.md). |
| **Done** | **A shared attempt record that both paths read and write.** Held in Redis, with per-attempt locking and repeat-safe start and submit, so the same request arriving twice does the work once. |
| **Done** | **A per-platform switch between the two paths.** Three settings — sockets only, both, endpoints only — flipped as a database value with no redeploy, plus counters that log which path each action actually arrived on. |
| **Done** | **The browser side of all of that.** Resume on load, a check-in every 30 seconds, a leave signal on tab close and on navigating away, and a banner for when live updates are unavailable. |
| **Remaining** | **Exactly three things still need the socket.** The push that opens a quiz, the push that ends it, and live peer presence in group quizzes. Everything else already works without one. |

So the requirements below are not new features. They are the places where the old machinery is
still load-bearing, and each is already written up as an undecided item in
[docs/cron-removal.md](cron-removal.md).

### The five behaviours in scope

Scope is defined by what the two crons do, and by nothing wider. `handleQuizes()` fans out
to four service calls; `sweepStaleAttemptSessions()` is the fifth behaviour.

| # | Behaviour | Where it is handled |
|---|---|---|
| 1 | `handleStartingQuizes` — pushes `quiz-start`, moves sockets from the waiting room to the quiz room | Requirement two, and mostly front-end step 6 — see "the start alarm has almost nothing to do" |
| 2 | `handleEndingQuizes` — pushes `quiz-end`, closes unsubmitted attempts | Requirement two |
| 3 | `handleWhatsappReminders` — the reminder sent before a quiz opens | Requirement four |
| 4 | `handleExpiredDurationQuizAttempts` — closes per-student duration attempts | Requirement two, "book per student" |
| 5 | `sweepStaleAttemptSessions` — pauses stale **quiz and practice** sessions | Requirement three |

Behaviour 5 is the one place this work reaches outside the quiz module: the sweep loops over both
`quiz` and `practice` sessions, so practice attempts have to be dealt with before it can be
deleted. That is scope inherited from the cron, not scope added here.

### One thing to confirm before going further

The current spec states plainly that **sockets are not going away** and will keep carrying quiz
start, quiz end and presence ([docs/quiz-practice-http-api.md](quiz-practice-http-api.md), first
paragraph). This plan reverses that for two of the three: the start and end pushes go, and per
decision 3 presence keeps its connection. It is a fine call to make — there is already a ticket for
deleting those events once the counters prove nobody is using them — but it is a change of
direction rather than a continuation, and that document needs updating so the next person reading it
does not follow the old plan. **Nothing below assumes a socket exists** — the connection survives
this work for presence, chat, notifications and calling, but no quiz timing guarantee depends on it.

---

## Requirement one — one clock, and it belongs to the server

The rule that makes this whole problem simple: **the browser is allowed to measure how much time
has passed, but never to decide what time it is.** Every deadline comes from the server, and
every deadline is enforced by the server. What the student sees on screen is a courtesy copy.

**Today.** The page asks the server for the time once when the quiz screen loads, then runs its
own arithmetic from that single reading for the rest of the attempt. Three separate things go
wrong in that arithmetic — see Findings. For fixed-window quizzes the countdown does not
actually count down.

**Proposed.** The server's current moment travels back on the same responses the page already
makes — starting, resuming, answering, checking in. No extra round trip. From any one of those
the page works out the gap between the server's clock and its own, and re-checks that gap
continuously for free.

- **Measure with the counter that cannot be tampered with.** Browsers expose a steadily
  increasing count of milliseconds since the page loaded, entirely separate from the device's
  calendar clock. It cannot be set, and it never jumps backwards over a sleep or a timezone
  change. Using it for the countdown means changing the system clock does nothing at all — which
  is the specific manipulation this is meant to close.

- **Correct against the deadline, don't count down towards it.** Rather than subtracting one
  second per tick from a stored number, each tick recomputes remaining time as "deadline minus
  now". A throttled background tab, a laptop lid closing, a slow frame — none of them accumulate
  error, because nothing is being accumulated.

- **Tick on a background thread, not the main one.** When a tab is hidden the browser
  deliberately slows down the main page's repeating timers — first to once a second, and in
  Chrome to **once a minute** after roughly five minutes out of sight. A small dedicated
  background thread is not held to that same limit, so moving the ticking there keeps the clock
  running at full speed through a long idle stretch. It also matters at the end: the moment the
  page decides time is up and submits on its own is only as prompt as its slowest tick, so a
  once-a-minute tick could delay that submission by up to a minute. The background thread holds
  the deadline and does nothing but count; drawing the clock and talking to the server stay where
  they are. The project's tooling supports this directly, so it needs no new package and no build
  configuration.

- **Re-sync at the moments that matter.** When the tab comes back to the foreground, when the
  connection returns, and whenever a resume happens. Each is a point where the page's assumptions
  may be stale and a fresh reading is nearly free.

- **Enforce, don't trust.** The server refuses an answer written after the deadline regardless of
  what the student's screen says, and refuses one for an attempt that is already closed. A
  tampered clock can therefore change the display and nothing else. This part already half exists
  — writes to a closed attempt are already rejected — and gets extended to cover the deadline
  itself.

- **Same treatment for both timing styles.** A fixed-window quiz has one end moment shared by
  everyone. A duration quiz gives each student their own span from their own start. Both reduce to
  a single server-issued deadline, which is what lets one countdown handle both instead of the
  three separate branches there today.

### These two fixes are deliberately belt and braces

The background thread keeps the clock ticking; recomputing from the deadline keeps it *correct*.
They are not the same fix and neither replaces the other. A phone that sleeps, a laptop lid
closing, or iOS suspending the page outright will still stop a background thread — nothing in a
browser can promise otherwise. What the second rule guarantees is that when it wakes, the very
next tick shows the right number rather than resuming from where it left off. Keep both: the
thread for a clock that stays smooth through an hour in a background tab, the recompute for a
clock that is never wrong when it comes back.

---

## Requirement two — the end of a quiz is an appointment, not a search

Right now the server asks the database, every five seconds, whether anything started in the last
five seconds or ends in the next five. That is **17,280 rounds of questions a day**, in every
running container, and the answer is almost always "no". The cost is not the wasted queries. It
is that each question is only ever asked about one five-second window, so **a single missed round
loses that moment permanently and silently** — the quiz simply never starts, or never closes.

```
Today      |||||||||||||||||||||||[ missed ]||||||||||||||||||||||
            ask every 5s          a deploy,   and the quiz's own end
            17,280 times a day    a restart,  moment falls inside it
            in every container    a slow query

Proposed   ─────────────────────────────────────────────●
            one alarm, booked when the quiz is scheduled,
            fires at the exact moment, survives restarts,
            retries on failure
```

- **Book the moment when the quiz is scheduled.** Two alarms per quiz: one for the start, one for
  the end. Rescheduling cancels and re-books; deleting cancels. The queue this needs was already
  adopted for exactly this class of problem and is already running — this is the fifth or sixth
  feature to use it, not new infrastructure. The hook points exist too: `adminCreateQuiz` and
  `adminUpdateQuiz` already call `scheduleQuizReminders`, so the alarms ride the same path.
  Cancelling on delete is the one part with no precedent to copy — `adminDeleteQuiz` cancels
  nothing today (finding 12).

- **The start alarm has almost nothing to do.** `handleStartingQuizes` writes nothing to the
  database — it is a socket push plus waiting-room bookkeeping, and front-end step 6 replaces it
  outright by counting down to a start moment the page already knows. The end alarm carries a
  guarantee and has to exist; the start alarm only needs to exist if something server-side has to
  happen at that moment, and today nothing does. Treat the pair as asymmetric, because it is half
  the work it first appears to be.

- **Book per student where the deadline is per student.** A duration quiz needs one alarm per
  attempt, due at that student's own deadline, booked when they begin. This is the case that has
  never worked properly: today it is an in-memory timer that dies on any restart and only ever
  existed for students on sockets (entry 10).

- **Name each alarm after the thing it is about.** Derive the name from the quiz or the attempt
  rather than generating a fresh one. Booking the same alarm twice then does nothing, so every
  container can try to book it and exactly one exists. This is the established pattern here and
  it is what makes the repair step below safe to run at any time.

- **Separate closing from announcing.** Today the closing of unsubmitted attempts sits inside the
  same loop as the socket broadcast, which ties the guarantee to the delivery mechanism. Closing
  the attempts is the guarantee; telling anyone about it is a courtesy that may fail. They should
  not be able to fail together.

- **Repair rather than reschedule.** No queue setting survives losing the queue, so there is a
  step — run at boot and available on demand — that recomputes which alarms ought to exist,
  re-books the missing ones, and closes anything whose moment has already gone by. Because the
  names are derived, this does nothing when nothing is wrong and repairs everything when
  something is. Idempotent repair, not a schedule in disguise. This is the same answer
  [docs/cron-removal.md](cron-removal.md) already reaches under "none of the above is the actual
  guarantee".

- **And a backstop that needs no moving parts at all.** The server refuses any write after the
  deadline and closes the attempt at that point. Even with the queue completely empty, nobody can
  answer past the end — the worst case becomes "the result screen appears a moment late", not
  "the quiz never ended".

---

## Requirement three — silence is the signal

A socket told you the moment someone vanished. Without one there is no event to catch — so the
design flips: **instead of watching for a departure, expect a regular sign of life and act when
it stops arriving.** Three signals, in order of how much you can rely on them.

| Signal | | |
|---|---|---|
| **Told** | Built | The page fires a leave signal when the tab closes or the student navigates away. Best-effort by nature — the browser is allowed to drop it, and on a hard crash or a yanked cable it never happens. Good when it arrives; never the guarantee. |
| **Heard** | Built | A small check-in every 30 seconds while the attempt screen is open. Every ordinary action already counts as one, so this only really covers a student sitting still reading a long question. |
| **Noticed** | Change | Today a sweep runs every 30 seconds and pauses anyone untouched for about 90 seconds. Instead: **each check-in books its own expiry, and the next check-in pushes it further out.** If the check-ins stop, the expiry fires on its own. Nothing scans anybody; the absence is itself the trigger. |

- **Tell a blip apart from a departure.** A short gap resumes silently and the student never
  knows. Past the grace period it is recorded as an interruption and the attempt is paused. That
  threshold is currently 90 seconds because that is what suited a sweep running every 30 — it was
  inherited, not chosen. **Decided: keep the 30-second check-in and set the grace to 95 seconds** —
  three missed check-ins plus a little slack. With no client-side retry (decision 4) a dropped
  check-in is simply gone, so the grace has to survive two consecutive losses. The value is already
  `process.env.attemptSessionStaleMs` (`AttemptSessionService.staleMs`, defaulting to 90s), so this
  is configuration rather than code. **Do not shorten it before front-end step 2 lands** — while the
  check-in is still a main-page timer, finding 6 applies and a tighter grace starts pausing healthy
  attempts. **Front-end step 2 landed 5 September 2026** (with step 5 - the check-in now runs on
  `heartbeatWorker.js`, immune to tab-visibility throttling), so this gate is now open: shortening
  95s is safe to consider on its own merits, though nothing has asked for it.

- **Practice attempts come along, or the sweep cannot go.** `sweepStaleAttemptSessions` loops over
  `['quiz', 'practice']` and calls `pausePracticeAttemptV2` for the second. Expiry-on-silence is
  described here in quiz terms, but the mechanism belongs to the attempt session rather than to the
  quiz, so the same check-in-books-its-own-expiry change covers practice with no extra design. The
  alternative is keeping the sweep alive for one caller, which leaves the five-second-cadence
  machinery standing. **Decided: extend it to practice**, so the sweep can be deleted outright.

- **Record why each attempt ended.** Submitted by the student, left deliberately, went quiet, or
  deadline reached. Today all four look identical afterwards, which is why "what happened to this
  student's attempt?" is currently unanswerable. This is the single highest-value small addition
  in the whole plan.

- **Count the interruptions, don't just note the last one.** A student who dropped out four times
  is a different conversation from one who dropped once. Same write, more use.

- **The check-in needs the background thread too — and this one is a live bug.** The 30-second
  check-in is a main-page timer, so it is slowed by exactly the same rule as the countdown. In a
  hidden tab it can stretch to a minute or more between check-ins, against a grace period of 90
  seconds. A student who leaves the quiz tab in the background to look something up can therefore
  be recorded as having gone quiet while their attempt is open and perfectly healthy. Moving the
  check-in to the same background thread as the clock closes that, and is a reason to do the
  front-end work before the presence change rather than after.

---

## Requirement four — the two-hour reminder belongs in the ladder that already exists

`handleWhatsappReminders` is the third of the four calls inside `handleQuizes`. It searches for
quizzes starting inside a five-second window some way ahead, then sends a WhatsApp message to every
registrant. It carries the same fragility as the start and end searches — one missed round loses
that send permanently and silently — plus two problems of its own.

**Most of the replacement is already built and running.** `src/quiz-reminder/` is precisely the
design Requirement two proposes: BullMQ delayed jobs due at `startTime - offsetHours`, job ids
derived from the quiz (`quiz-reminder-q{id}-h{hours}`), a boot `reconcile()` that re-adds whatever
is missing without being a schedule in disguise, and a per-recipient ledger whose
`UNIQUE(blastId, userId)` makes a double run harmless. It runs a two-step ladder — 168 hours and 24
hours before the start — over email. The WhatsApp reminder is a third step at roughly two hours
that never got migrated.

- **Add it as a step, don't rebuild it.** One entry in `REMINDER_STEPS`, scheduled by the same
  `scheduleForQuiz` already called from `adminCreateQuiz` and `adminUpdateQuiz`. Nothing new is
  needed at the scheduling end, and the boot reconcile covers it for free.

- **The real work is the channel, not the timing.** The ladder is welded to email: `EmailSend`,
  `EMAIL_SEND_CATEGORY`, Brevo template ids, `ReminderSendJobData.senderEmail`. A WhatsApp step
  needs either a channel dimension on the step definition and the ledger, or a `MessageSend`-backed
  mirror of the send job. `src/whatsapp-reminder/` already has the `MessageSend` shape to copy —
  one row per recipient, written before the message leaves.

- **Write the ledger row before sending, because today there is none.** The current loop sends and
  records nothing, so "did this student get their reminder?" is unanswerable, and the send is not
  idempotent — every container runs this cron, so N containers means N copies of every WhatsApp
  message, identical to the problem the newsletter and half-hourly crons were already retired for
  ([docs/cron-removal.md](cron-removal.md)). This one is still live.

- **Settle the offset while migrating it.** The current code sends at `startTime - 102 minutes`
  against a template named `twoHourReminder`. That is finding 8, and writing the step forces the
  question: `offsetHours: 1.7` preserves today's behaviour, `offsetHours: 2` matches the template
  name and the intent. **Recommendation: 2**, treating the current value as the bug it looks like.

---

## The front-end plan (`LMS_V2`)

Most of the groundwork is in place — resume on load, the check-in, the leave signal, the
transport switch and the error handling all landed with LMS_V2 #82–#88. What follows is the
remaining work, in the order it should be done, keyed to the files it touches. Steps 1 to 3 are
pure front end: no server change, no new package, and they fix four live bugs on their own.

### 1. One place that knows the time

Today the countdown does its own arithmetic from a single reading, and nothing else on the screen
knows when the attempt ends. The store holds the attempt as one blob
(`src/redux/slices/mock-quiz/mockQuiz.js` keeps `attempt` and nothing about time), so every
consumer that needs a deadline re-derives it.

Derive three facts once, when an attempt is started or resumed, and keep them in one place the
rest of the screen reads: **the gap between the server's clock and this device's**, **the
attempt's deadline**, and **the time already accrued**. The countdown, the enabled state of the
answer controls, and the submit-at-zero then all become readers of the same fact instead of three
independent calculations that can disagree.

This is the step everything else leans on, and it is the reason the manipulation you asked about
closes: there is exactly one place where a device clock could have entered the system, and it
does not.

### 2. The clock moves to a background thread

One small file that does nothing but hold a deadline and count. It reports ticks back; it draws
nothing and calls nothing.

**It owns the check-in cadence too.** That is what closes finding 6 — one background thread with
two consumers, the countdown and the check-in, rather than two throttled main-page timers.

Worth knowing on precedent: the app already ships a worker for the PDF viewer, but that is a
prebuilt file loaded by URL (`src/components/CustomPdfViewer.jsx`). This would be the first one
written in the project. Vite supports it with no configuration and no dependency.

What deliberately stays on the main thread: rendering, and **every network call**. The background
thread has no session and no headers, and giving it any would be the wrong seam. It says "time is
up" or "check in now"; the main thread decides what to do about it.

### 3. `QuizTimer.jsx` becomes one implementation

Three branches collapse to one, reading the shared deadline from step 1 and ticking from step 2.
Fixed-window and duration quizzes both render remaining time; open-ended renders elapsed. This
single change fixes findings 1, 2 and 3.

### 4. The page decides the quiz is over, then confirms

**✅ Done, 5 September 2026.** `src/pages/QuizExam.jsx` used to wait for a push to learn the quiz
has ended, and separately re-checked the attempt only when the socket reconnected. Both changed,
and the old socket paths were left running alongside — deleting them is step 7, once the counters
say nobody needs them, matching the dual-run pattern the backend steps used throughout.

- **The auto-submit** rides `quizExpired`, a new `mockQuizes` slice field `QuizTimer` sets once,
  the moment its background worker's countdown reaches zero (front-end steps 1-3) — it lives in
  the store rather than a prop because `QuizTimer` renders under `QuizTopBar`, not under
  `QuizExam`. A new effect in `QuizExam` reacts by locking input immediately
  (`dispatch(setHasSubmitted(true))`, before the network call resolves — the deadline has
  genuinely passed, there's nothing to wait on the server for), calling the existing
  `submitQuizAttempt`, and navigating via a new shared `getPostSubmitRoute(attempt, params)`
  util (extracted from `QuizConfirmSubmitPopup`'s inline `navigateAfterSubmit`, now used by both,
  so the manual-submit and auto-submit-at-zero flows can't disagree about where a submitted
  attempt leads). A 409 (already submitted/ended) is treated as the terminal state it's racing
  towards, not a failure. Any other failure is a genuine refusal — input stays locked regardless
  (the server already refuses writes past the deadline either way, per step 3's
  `hasQuizAttemptDeadlinePassed`), and a toast says why the screen didn't move rather than
  silently retrying or pretending the submission went through; the recheck below is what
  eventually resolves it if the attempt did in fact close server-side. Guarded fire-once by
  `hasSubmitted` itself in the effect's own dependency array. Races harmlessly against the
  still-live `quiz-end` socket listener — `submitQuizAttempt` is idempotent server-side
  (GrowthCommand#211), so whichever gets there first wins and the other's follow-up is a no-op.
- **The re-check** is now a shared `recheckAttempt` callback, called from three places: the
  existing socket-manager `reconnect` listener (unchanged trigger, kept for the socket transport),
  a new `window` `online` listener, and a new `document` `visibilitychange` listener (fires on
  `document.visibilityState === "visible"`) — the exact two moments the plan names, and the first
  time an HTTP-only platform has had ANY re-check at all, not only a socket one. It also closes
  order-of-work step 2's open item above: `GET /quiz/attempt/current` now carries `serverTime`
  too (**backend change**, `QuizService.getCurrentQuizAttemptV2`), and the recheck re-derives the
  clock anchor from it — but only for a fixed-window quiz, per the reasoning above.
- **The toggle-off hazard** (below) is closed in `Option.jsx`: a local `saveState`
  (`null`/`"saving"`/`"failed"`) tracks the LAST CLICK's own outcome, separately from the
  persisted selection. A failed save now shows "Not saved — tap to retry" in amber, distinct from
  both the saved-and-selected style and the plain unselected one; a second click while a save is
  in flight is a no-op rather than a second concurrent request. The essay path
  (`Question.jsx`) gets the analogous fix: a local `essaySaveFailed` flag (reset on every new
  keystroke, and on question change) renders a persistent "Not saved" line under the textarea,
  since the toast alone had faded by the time a student who wasn't watching for it might notice.
  22 new/changed Vitest tests across `getPostSubmitRoute` (4, new util), `QuizTimer` (1, the
  `quizExpired` dispatch), and `mockQuizAttemptErrors.test.jsx` (2 new + 1 strengthened, over
  `Option`'s failed/retry states) — the auto-submit effect, the anchor-refresh branch and the
  essay indicator are reviewed but not unit-tested here (all three are exercised together with the
  rest of the page in front-end step 8's reserved test cases). One guard verified by mutation
  (removing `setSaveState("failed")` failed both of `Option`'s new tests, restored). Full frontend
  suite (949 tests), ESLint and Vite build all green.
  Backend side: 2 changed Jest tests in `quiz.service.attempt-v2.spec.ts` (the identity-equality
  assertion `getCurrentQuizAttemptV2` used to satisfy no longer holds now that it spreads in
  `serverTime`; a null-session test was added alongside it), one guard verified by mutation
  (reverting the method to its old one-line pass-through fails to even type-check, since the test
  now asserts a field the old return type didn't carry — TypeScript itself is the mutation-catcher
  here). `quiz.attempt-parity.spec.ts` and `quiz.controller.attempt-v2.spec.ts` needed no changes
  (neither asserts the response by identity or deep-equality). 67 tests across the three files,
  `tsc --noEmit` clean.

**One hazard survives the decision to drop offline handling, and it is not obvious.** Sending the
same option again *toggles it off* server-side — documented, intended behaviour. If an answer saves
but its response is lost in transit, a student who clicks the same option again to make sure
**unsets the answer they had successfully given**. Decision 4 removes the replay queue that would
have done this automatically; it does not remove the hazard, it moves it to the student. So the
screen has to make the saved state of the current answer unambiguous, and a failed answer has to
read as *failed* rather than as unanswered. **Closed 5 September 2026** — see the bullet above.
The hazard itself (re-clicking a genuinely successful save unsets it) is unchanged and cannot be
closed from the client alone; what changed is that a student now has an honest, persistent signal
telling them whether the click before this one actually landed, so they have no reason to guess by
re-clicking.

### 5. The check-in and the leave signal

**✅ Done, 5 September 2026.** `src/hooks/mock-quiz/useAttemptLifecycle.js` keeps the leave beacon
on tab close, page hide and unmount untouched — it stayed on the main thread, because it is a
network call fired during unload, and the fire-once latch was left exactly as it stood.

The heartbeat interval moved to a background thread, as step 2 called for — but to its **own**
dedicated worker (`LMS_V2/src/workers/heartbeatWorker.js`, new), not the countdown's. Sharing one
literal `Worker` instance between `QuizTimer` (a component under `QuizTopBar`) and this hook (called
directly in `QuizExam`) would have meant lifting `QuizTimer`'s worker instantiation out to a common
ancestor or a context, purely so two unrelated concerns could share a thread that neither needs
much of. The plan's own reasoning for step 2 — "one background thread ... rather than two
throttled main-page timers" — is an argument about **not being throttled**, which a second tiny
worker satisfies exactly as well as sharing one would; the architectural cost of the sharing did
not buy back anything the two-worker version doesn't already have. `heartbeatWorker.js` is even
simpler than `quizClockWorker.js`: it holds one `setInterval` and reports one message type
(`{type: "tick"}`), with no anchor/baseline math at all — matching its own job, a plain cadence,
not a value. Unlike the clock worker's "start" (which posts an immediate tick, for display), this
one's first tick fires only after a full interval, matching the `setInterval` it replaces — a
heartbeat at mount would be redundant, since the attempt start/resume call that got the student
here already just refreshed `lastSeenAt`.

`useAttemptLifecycle` itself changed only inside its heartbeat branch: `setInterval`/`clearInterval`
became `new HeartbeatWorker()` / `worker.postMessage({type: "start", intervalMs})` /
`worker.terminate()`, gated the same way as before (no `onHeartbeat` → no worker created at all).
The network call itself (`onHeartbeat`, i.e. `heartbeatQuizAttempt`) still runs on the main thread,
same as every other attempt call — the worker only ever reports a tick back.

10 new Vitest tests (`useAttemptLifecycle.test.js`, new — the hook had no test file before this),
covering the unchanged beacon behaviour (fire-once across both browser events, unmount, no-op
with no attempt id, a throwing `onPause` logged not crashed) alongside the new heartbeat wiring
(no worker created without `onHeartbeat`, the worker started at the default and at a caller-
supplied cadence, `onHeartbeat` called only on a `"tick"` message and not on any other, a throwing
`onHeartbeat` logged not crashed, and the worker terminated on unmount alongside the pause firing).
One guard verified by mutation (dropping the `event.data?.type !== "tick"` check failed the
"not on any other message" test, restored). Full suite (959 tests, up from 949), ESLint and Vite
build clean; both `heartbeatWorker.js` and `quizClockWorker.js` bundle as separate chunks.

### 6. The waiting room

**✅ Done, 5 September 2026.** Initially investigated and deferred by request pending the one open
design question below; the answer came back **"just enable the button"** — the countdown flips the
card back to its normal Start/Resume/etc. buttons once it reaches zero, and nothing is fired
automatically on the student's behalf.

**The decision that was open, now settled:** the plan's own line — "the open request needs a small
random spread so they do not arrive in the same instant" — reads most naturally as a concern about
something automated firing the request, since a human clicking a newly-enabled button already
spreads out over seconds on its own. That reading would have meant auto-starting the attempt.
**Decided against** — the button is simply enabled; no attempt is started, and no jitter/spread
was needed, because nothing fires automatically at all. The "spread" framing in the plan text
doesn't apply to what was actually built.

**The current workflow, before this step (confirmed by tracing the code):**
`startTime`/`endTime` are optional fields an admin sets when scheduling a quiz
(`AdminCreateQuizDto`/`AdminUpdateQuizDto`), gating anything only when `Quiz.timeType` is `fixed`
or `duration` — a `wait`/`wait-optional`/`free` quiz ignores them and is always open. Both
start-attempt paths already correctly refuse an early start server-side: `startQuizInternal`
(socket, `quiz.service.ts:3084-3103`) and `startQuizAttemptV2Locked` (HTTP,
`quiz.service.ts:5288-5308`) both check `startTime > now` and reject with "Quiz not started yet".
On the socket transport, a refused start also does `client.join(waitingRoom)`
(`waitingroom_quiz_{id}`); the cron `handleStartingQuizes` (`quiz.service.ts:7243-7279`, every 5s)
finds quizzes whose `startTime` just arrived and pushes `quiz-start` to that room, moving every
socket in it to `quizroom_quiz_{id}` — a pure socket reshuffle, writing nothing to the database,
matching this step's own framing ("the start alarm has almost nothing to do"). **But nothing in
the frontend listens for `quiz-start` anywhere** — confirmed by grep, the only three hits for the
string are an unrelated toast id (`"mock-quiz-start"`). So before this step, in practice: no live
waiting-room experience at all — a student on the page when a quiz opened saw nothing change
automatically, and had to reload or click Start again once the real time had passed.

**A real, pre-existing display bug was found and fixed alongside this step**:
`LMS_V2/src/utils/mock-quiz/identifyQuiz.js`'s "quiz not started" branch cleared
`showResume`/`showStartOver`/`showResult` but never cleared `showStart` — so the Start button
could render as clickable before the quiz opened, even though clicking it was always safely
refused server-side. Fixed by clearing `showStart` too and adding a new `showWaiting` flag the
card now reads. `EachExam.jsx` also duplicated this same function's logic inline rather than
importing the shared util `ChildQuizCard.jsx` already used — pre-existing duplication, not
introduced by this work, converged onto the one shared `identifyQuiz.js` as part of this fix (it
could not be fixed safely in one copy without both having the fix).

**What was built:** `src/components/quizes/mock-quiz/QuizWaitingCountdown.jsx` (new, `LMS_V2`) — a
small pill reusing the SAME generic, worker-driven countdown machinery from front-end steps 1-3
(`quizClockWorker.js`, mode `"countdown"`), anchored off the DEVICE clock (`Date.now()`), not a
fresh server reading. That's deliberate: this countdown is advisory UI only, the real gate is the
server's own check on the start-attempt call regardless of what this shows, so no backend change
and no extra round trip was needed — matching this step's original "pure front end" scope. It
calls `onOpen()` once, the moment the countdown expires; both `EachExam.jsx` and `ChildQuizCard.jsx`
wire that to a local `hasOpened` flag that, combined with the freshly-derived `showWaiting`,
decides whether to render the countdown or the normal button row — no re-fetch of anything, since
nothing about the quiz's own data changes just because time passed.

16 new Vitest tests: `identifyQuiz.test.js` (+3, the bug fixed and the waiting flag's boundaries),
`QuizWaitingCountdown.test.jsx` (5, new file — baseline derivation, tick display, the `onOpen`
call, worker teardown, no-op with no `startTime`), `EachExam.test.jsx` (+2) and a new
`ChildQuizCard.test.jsx` (2, the component's first test file) — both covering the wiring itself:
the countdown shows instead of Start while waiting, and the button is enabled (with
`startQuizAttempt` asserted NOT called) once it opens. Two guards verified by mutation (forcing
`isWaiting` false in each of `EachExam.jsx`/`ChildQuizCard.jsx` failed their own new tests,
restored). Full suite (983 tests, up from 971), ESLint and Vite build clean.

With a few thousand students all due at the same second, the open request needs a small random
spread so they do not arrive in the same instant. That is a deliberate design detail, not an
afterthought.

### 7. What gets deleted, and only at the end

Once the counters show nobody is using the pushes, and per platform via the switch that already
exists:

- `src/components/quizes/mock-quiz/SocketPushWarning.jsx` — goes entirely.
- The end-of-quiz listener and the socket reconnect hook in `QuizExam.jsx`.
- `useSocketReady` for quiz purposes; `useTransportReady` collapses to always-true and can follow.
- The socket branch inside `quizAttemptTransport.js`, and the `devQuizPracticeTransport` override
  with it.

Deleting these is the last step, not the first.

**Not here any more:** an offline hold-and-replay layer in `quizAttemptTransport.js`. Decisions 2
and 4 removed it — every quiz action is an HTTP request, a failed request raises a toast, and
nothing is queued. The transport keeps normalising failures into one error type, which is all the
page needs to render a failure honestly.

### 8. Tests worth having

**✅ Done, 5 September 2026 — taken out of order, ahead of steps 6/7, since both of those are
blocked (step 6 deferred by request, step 7 gated on live usage counters) while step 8's four
cases were fully actionable against what had already landed.**

Vitest and Playwright are both set up, and there is already a pattern to follow in
`src/sections/quizes/mock-quiz/quiz-content/__tests__/mockQuizAttemptErrors.test.jsx`. Four cases
are worth writing:

1. **Moving the device clock forward mid-attempt changes the displayed time by nothing.** New
   `QuizTimer.test.jsx` case: renders with `Date.now` monkey-patched a full day forward for the
   entire test, and asserts the worker still receives the identical baseline range the untampered
   test next to it does — proving the property end-to-end (real `performance.now()`, a tampered
   `Date`) rather than by source inspection alone.
2. **A long stretch with the tab hidden leaves the clock correct on return.** New `QuizTimer.test.jsx`
   case: posts a single `tick` reflecting a 5-minute jump (simulating the worker's own next tick
   after a long hidden stretch — real browsers don't throttle Web Workers the way they throttle a
   main-page `setInterval`) and asserts `QuizTimer` displays it correctly, with no accumulation
   logic of its own to have drifted. `computeQuizClockValueMs.test.js` already had the
   pure-function half of this (recompute-from-baseline after a large `elapsedMs` gap, exact, no
   drift) from front-end step 1.
3. **A write attempted after the deadline is refused, and the page handles the refusal.** New
   `mockQuizAttemptErrors.test.jsx` case, using the EXACT message and status
   `hasQuizAttemptDeadlinePassed`'s guard throws server-side (`ConflictException('The time for
   this attempt has run out')`, 409) — asserting `Option.jsx` shows the server's own message and
   marks itself failed (case 4's mechanism), rather than a generic simulated 409.
4. **A failed answer renders as failed — not as saved, and not as unanswered.** Already covered on
   the MCQ side by front-end step 4's `Option.jsx` tests (now labelled `case 4` for traceability).
   The essay side had NO test at all until now — new `Question.essayFailure.test.jsx` (3 tests):
   the persistent "Not saved" notice appearing after the debounced autosave fails, clearing on the
   next keystroke, and staying silent on a successful save.

6 new Vitest tests total, one guard verified by mutation per new file (removing
`Question.jsx`'s `setEssaySaveFailed(true)` failed 2 of its 3 new tests, restored — the other
three cases needed no separate mutation check, since they reuse mechanisms (`Option.jsx`'s
`saveState`, the worker's tick-display path) already mutation-verified in earlier steps). Full
suite (971 tests, up from 965), ESLint and Vite build clean.

---

## Findings — already broken today, found while reading

These are not consequences of the plan; they are live now. Four of them fall out naturally as
part of the countdown rewrite.

1. **Fixed-window quizzes do not count down.** The server's time is read once and stored, then
   every tick computes "end time minus that stored reading" — the same two fixed numbers, over
   and over. The displayed remaining time never changes for the length of the quiz.
   *`LMS_V2/src/components/quizes/mock-quiz/QuizTimer.jsx`*

2. **Duration quizzes drift slow and never recover.** The countdown subtracts one second per tick
   from a local number. Browsers deliberately slow those ticks down in a background tab, so a
   student who switches away comes back to a clock showing more time than they have, with nothing
   to correct it. *same file*

3. **Open-ended quizzes measure elapsed time with the device's own clock.** Time spent is computed
   against the calendar clock, so moving the system clock forward inflates it. Exactly the
   manipulation this work is meant to close. *same file*

4. **Quizzes can close up to five seconds early.** The ending search looks for quizzes ending
   between now and five seconds *from* now — a window in the future rather than the past.
   Whichever round catches a quiz, it is caught before its time is actually up.
   *[src/quiz/quiz.service.ts](../src/quiz/quiz.service.ts), the ending sweep*

5. **Auto-submit is welded to the announcement.** Closing unsubmitted attempts happens inside the
   same loop that broadcasts the end. The guarantee and the courtesy share a failure. *same file*

6. **A backgrounded tab can be recorded as having gone quiet.** The 30-second check-in is a
   main-page timer and is slowed by the same browser rule as the countdown — to once a minute or
   worse in a hidden tab, against a 90-second grace period. The margin the design assumes is only
   there while the tab is in front.
   *`LMS_V2/src/hooks/mock-quiz/useAttemptLifecycle.js`*

7. **The cheating report endpoint has no limit on the server side.** Already documented as
   outstanding: a burst of reports creates a burst of rows, with only the browser's own restraint
   in the way. Worth closing while we are in this module.
   *[docs/quiz-practice-http-api.md](quiz-practice-http-api.md) — "not rate-limited server-side"*

8. **✅ Fixed, 5 September 2026, in step 6. The two-hour WhatsApp reminder fired at one hour
   forty-two.** The window was computed as `now + 102 * 60 * 1000`, against a `QuizTemplate` named
   `twoHourReminder`. Settled at exactly 2 hours, matching the template's name.
   *`src/quiz-reminder/quiz-reminder.constants.ts`, `REMINDER_STEPS`*

9. **✅ Fixed, 5 September 2026, in step 6. That reminder was unledgered and unguarded.** No
   `MessageSend` row was written, so who was reached was unknowable and the send was not
   idempotent, and there was no per-recipient `try/catch`, so a single bad number aborted the
   remaining recipients for that quiz and every quiz after it in the same round.
   `QuizReminderService.runWhatsappStep`/`runSendWhatsapp` write the ledger before sending and
   isolate each recipient's send behind its own BullMQ job, the same shape as the email steps.
   `QuizService.handleWhatsappReminders` itself is untouched and still live - see step 6's note on
   why. *`src/quiz-reminder/quiz-reminder.service.ts`*

10. **Fixed-window auto-submit closes attempts incompletely.** `handleEndingQuizes` sets
    `hasSubmitted: true` via `updateMany` and nothing else — no `timeTaken`, and no
    `attemptSessionService.clearQuiz`. `handleExpiredDurationQuizAttempts` does both for the
    duration case. So ending a fixed-window quiz leaves a live Redis attempt session behind and a
    null `timeTaken`, and the two paths disagree about what "closed" means. It also has no per-quiz
    `try/catch`, so one failure stops the rest of the round. *same file*

11. **The duration sweep scans without bounds.** `handleExpiredDurationQuizAttempts` fetches *every*
    open duration attempt with `include: { Quiz: true }` and filters the deadline in JavaScript,
    every five seconds. There is no time predicate in the query, so the set only grows as abandoned
    attempts accumulate. Per-attempt alarms fix this, which is an argument for doing that step
    early rather than last. *same file*

12. **✅ Fixed, 5 September 2026, in step 4. Deleting a quiz did not cancel its scheduled jobs.**
    `adminDeleteQuiz` cancelled nothing. **Correction to this finding's own original wording:**
    it's not that no cancel method existed — `QuizReminderService.removeForQuiz` was already
    there, it was simply never called from `adminDeleteQuiz`. Both that call and the new
    `QuizEndService.removeForQuiz` are wired in now. Was harmless in practice (the delayed job
    just fired into an empty lookup), but was the missing half of "rescheduling cancels and
    re-books; deleting cancels" in Requirement two.
    *[src/quiz/quiz.service.ts](../src/quiz/quiz.service.ts), `src/quiz-reminder/`,
    `src/quiz-alarms/` (`quiz-end.*` — moved here 5 September 2026, see the note under step 5)*

13. **~~The frontend's server-time reading was 5.5 hours off, and it broke fixed-window quizzes
    specifically.~~ Fixed 5 September 2026, front-end step 1.** `GET /time`
    (`AppController.getTime`, [src/app.controller.ts](../src/app.controller.ts)) adds a hardcoded
    5.5-hour "IST" offset before returning the current instant. That's harmless for a duration
    quiz — the offset is on both sides of `deadline − now`, since both come from the same reading
    — but `QuizTimer.jsx` compared that reading directly against `Quiz.endTime`, a real, unshifted
    timestamp from a different source, so every fixed-window countdown read up to 5.5 hours short
    of the real remaining time. Finding 1 (the countdown was frozen at mount) had been masking how
    visible this was.
    First fix pointed the frontend at `GET /iso-time`, an already-correct, unused sibling route
    (`now.toISOString()`, no shift) — no backend change. **Superseded the same day**: a standalone
    time endpoint, even a correct one, was the wrong shape — the server's clock rides the attempt
    start/resume response now instead (`serverTime`, added directly to `startQuizAttemptV2Locked`'s
    and the socket path's `make-quiz-attempt-success` return — see step 2, now also done). No
    dedicated time endpoint is called at all any more, and `/time` and `/iso-time` are both fully
    unused again — worth a follow-up ticket to delete `/time`, since nothing depends on its bug any
    more either.

14. **✅ Fixed 5 September 2026, found while starting front-end step 6, in the same family as
    finding 13. Starting a quiz from the listing page showed no timer at all.** `QuizExam.jsx`'s
    own load effect is the ONLY place front-end step 1 wired
    `dispatchQuizClockAnchor`/`setQuizClockAnchor` into — but it isn't the only place that calls
    `startQuizAttempt`. `EachExam.jsx`, `ChildQuizCard.jsx` and `StartQuizPopup.jsx`
    (`LMS_V2/src/sections/quizes/mock-quiz/exams/EachExam.jsx`,
    `LMS_V2/src/components/quizes/mock-quiz/{ChildQuizCard,StartQuizPopup}.jsx`) each call
    `startQuizAttempt` themselves from the quiz-listing page, then dispatch `setMockQuestions`
    and navigate to `QuizExam` — and that pre-populated `questions` state is exactly what
    `QuizExam`'s load effect gates on to skip re-fetching
    (`if (questions && questions.length > 0) return;`), so for the ordinary "click Start on the
    listing page" path, `QuizExam`'s load effect never ran at all and the anchor was never
    dispatched. A page reload/direct-URL resume was unaffected, since `questions` is genuinely
    empty on a fresh mount there.
    New `LMS_V2/src/utils/mock-quiz/dispatchQuizClockAnchor.js` is the one place that now derives
    and dispatches the anchor from a `startQuizAttempt` response; all four call sites (the three
    above, plus `QuizExam.jsx`'s own load effect, refactored onto the same helper) call it right
    after `dispatch(setAttempt(...))`, so a fifth call site can't reintroduce the same gap. 6 new
    Vitest tests (3 for the helper itself, 2 for `StartQuizPopup`'s resume flow, 1 for `EachExam`'s
    full Start → disclaimer → attempt flow), two guards verified by mutation (reverting either
    component's one-line fix failed its own new test, restored). Full suite (965 tests, up from
    959), ESLint and Vite build clean.

---

## Order of work

Sequenced so each step is safe on its own and nothing lands as a big bang. The old machinery keeps
running alongside the new until the counters say it can go.

1. **✅ Done, 5 September 2026. Rewrite the countdown, and move its ticking to a background
   thread.** Fixes three visible bugs immediately, and independent of everything else here. Start
   here. Landed as `LMS_V2/src/workers/quizClockWorker.js`,
   `src/utils/mock-quiz/{computeQuizClockValueMs, deriveQuizClockAnchor}.js`, a rewritten
   `QuizTimer.jsx`, and the `quizClockAnchor` field on `mockQuiz.js` — plus finding 13 above, found
   and fixed along the way. Ended up pulled together with step 2 below (see there for why); no
   longer strictly "no server change" as originally scoped, but still one self-contained unit of
   work landed together. 13 new Vitest tests; full suite (942 tests), lint and build all green.
2. **✅ Done, 5 September 2026, together with step 1. Put the server's current moment on the
   attempt responses.** Originally planned as its own step; folded in immediately because step 1's
   first cut called a dedicated time endpoint, which is exactly the shape this step exists to
   avoid — better to land the two together than build the wrong thing first. `serverTime` (an ISO
   timestamp) now rides `startQuizAttemptV2Locked`'s HTTP response and the socket path's
   `make-quiz-attempt-success` alike, since the attempt start/resume call already runs on every
   page load and resume. `QuizExam.jsx`'s load effect derives the anchor from it and dispatches
   `setQuizClockAnchor` right alongside `setAttempt`; `QuizTimer.jsx` fetches nothing itself any
   more, only reads the anchor. One open item this created: the tab-focus/connection-back re-sync
   this step's frontend half used to get from query refetch triggers has no replacement yet — it's
   covered once front-end step 4 lands ("on regaining connection or on the tab regaining focus,
   re-ask for the current attempt"), which will refresh `serverTime` as a side effect of the same
   re-check. Until then, the anchor is only as fresh as the last load/resume.
   **Closed 5 September 2026, in step 4** — but only for a fixed-window quiz. `GET
   /quiz/attempt/current` (`QuizService.getCurrentQuizAttemptV2`) now carries `serverTime` too,
   alongside the session; `QuizExam.jsx`'s recheck re-derives the anchor from it, gated on
   `attempt?.timeType === "fixed"`. A duration quiz's baseline bakes in `timeTaken` as read at the
   ORIGINAL anchor — recomputing it later from that same stale reading would restart the countdown
   from where it stood at the first anchor, running it backwards from what the worker had already
   correctly ticked down to, which is worse than leaving it alone. Its own baseline is already
   immune to `serverTime` staleness by construction (`deriveQuizClockAnchor`'s own comment: it
   "does not actually depend on `serverNowMs`"), so nothing is lost by not refreshing it here.
3. **✅ Done, 5 September 2026. Extend the deadline check on writes.** The backstop that makes
   everything after this optional rather than critical. Cheap, and worth having before the rest.
   New `QuizService.hasQuizAttemptDeadlinePassed(quiz, attemptCreatedAt)` mirrors
   `deriveQuizClockAnchor` on the frontend, and is called from all four answer-writing paths, both
   transports: `addOptionQuizQuestion(Internal/V2Locked)` and
   `addEssayQuizQuestion(Internal/V2Locked)`. Deliberately **not** called from submit - a submit
   arriving a moment after the deadline (the client noticing zero and submitting) is still the
   honest last word, not a write to refuse - and not from `markEssayQuizQuestion*`, which only ever
   runs post-submission grading. 7 new Jest tests (duration and fixed-window, both the rejection
   and a not-yet-expired control); one of the four call sites verified by mutation (removing the
   check and confirming its test fails). Full quiz-attempt suite (74 tests) green, `tsc --noEmit`
   clean, ESLint clean (net of 2 unrelated pre-existing formatting errors the autofix also swept up
   in the same spec file).
4. **✅ Done, 5 September 2026. Book the end alarm for fixed-window quizzes,** running alongside
   the five-second search (both repeat-safe, so both firing is harmless — that is what makes the
   comparison possible during the dual-run). Closed finding 10 as part of doing this properly
   rather than copying the old cron's incomplete close: the alarm sets `hasSubmitted`, computes
   `timeTaken` from `endTime − attempt.createdAt`, and clears the Redis session, all three of which
   `handleEndingQuizes` still skips. The old search is unchanged for now — it will need the same
   fix or deletion outright when step 8 removes it, whichever comes first. The start alarm was not
   built — per the note on Requirement two, there is still nothing server-side for it to do.
   New module `src/quiz-end/` (`quiz-end.constants.ts`, `.service.ts`, `.processor.ts`,
   `.module.ts`), matching `quiz-reminder`'s conventions: derived job id (`quiz-end-q{id}`), boot
   reconcile (add-only, 24h grace), `adminCreateQuiz`/`adminUpdateQuiz` schedule it
   (`replace: true`), `adminDeleteQuiz` cancels it. **Also fixed finding 12 while wiring
   `adminDeleteQuiz`**: `QuizReminderService.removeForQuiz` already existed but nothing called it —
   it does now, alongside the new alarm's own cancellation. Separates closing (must succeed, retries
   on failure) from announcing (best-effort, its own try/catch, cannot undo or block a close already
   committed) per Requirement two. Re-reads the quiz fresh before closing anything and no-ops if
   `endTime` has moved to the future since the job was booked - the guard against the one race a
   `replace: true` reschedule can't close (a job already mid-flight when the remove runs).
   18 new Jest tests (scheduling eligibility, reconcile, the close/announce split, the stale-job
   race, one bad attempt not stopping the rest), one verified by mutation. Full quiz + quiz-end
   suite (156 tests, net of the 12 pre-existing unrelated failures) green, `tsc --noEmit` clean,
   ESLint clean (net of the same pre-existing unused-var debt scattered through
   `quiz.service.ts`, unrelated to this change and unchanged in count).
5. **✅ Done, 5 September 2026. Book per-student alarms for duration quizzes.** Same dual run — the
   old `handleExpiredDurationQuizAttempts` sweep is unchanged and still running. First time this
   case works across a restart, and closes finding 11: the new alarm is booked once per attempt at
   start/resume time (whichever `startQuizAttemptV2`/`startQuizInternal` call happens to run,
   idempotent at the same derived job id either way) rather than found by scanning every open
   duration attempt every five seconds. Cancelled on submit — not load-bearing (the job re-checks
   `hasSubmitted` and no-ops on its own), just no reason to leave dead work booked.
   Same close/announce split as step 4, same stale-job-race guard (re-reads the attempt and
   recomputes the deadline before closing), and the same payload shape
   `handleExpiredDurationQuizAttempts` already sent (`{quiz: attempt.Quiz}`, not `{quizId}` —
   deliberately kept asymmetric with step 4's payload rather than unified, since nothing asked for
   that and it would risk breaking whatever currently reads it).
   **The limitation this left — closed the same day, on request.** A quiz's `duration` being
   edited after an attempt already started used to mean that attempt's alarm kept firing against
   the stale duration it was booked with: it would find the recomputed deadline still ahead and
   no-op, with nothing to re-book it for the new time. `QuizAttemptEndService.rescheduleForQuiz(quizId)`
   closes this — called from `adminUpdateQuiz`, unconditionally, the same convention as
   `scheduleQuizReminders`/`scheduleQuizEndAlarm`: finds every open attempt of that quiz and
   re-books each one's job (remove then add, same as a single attempt's own `replace: true`)
   against whatever `duration` now is. What remains is only the one race no `replace` can close —
   a job already mid-flight the instant the reschedule's remove runs — which is exactly what the
   existing stale-deadline guard on `runEnd` was already built to catch, from the other direction.
   Even without either, step 3's `hasQuizAttemptDeadlinePassed` enforces the *current* duration on
   every write regardless of whether this alarm ever fires at the right moment - so the actual
   guarantee was never at risk, only the auto-close's punctuality.
   New module `src/quiz-attempt-end/` (same shape as `quiz-end/`: constants, service, processor,
   module). 21 new Jest tests, two guards verified by mutation. Full quiz + quiz-end +
   quiz-attempt-end suite (177 tests, net of the same 12 pre-existing unrelated failures) green,
   `tsc --noEmit` clean, ESLint clean (net of the same pre-existing unused-var debt, unchanged in
   count).
   **Merged into `src/quiz-alarms/`, 5 September 2026, by request.** `quiz-end/` and
   `quiz-attempt-end/` were two separate modules — reasonable on their own (each owns one BullMQ
   queue/processor, matching `quiz-reminder/`'s existing shape), but the two are close enough to
   twins (same schedule/remove/reconcile/runEnd shape, same close-then-announce split, differing
   only in per-quiz vs. per-attempt) that three near-identical module skeletons for one overall
   concern (enforcing a quiz's end) was more separation than warranted. Folding them into
   `quiz.module.ts`/`quiz.service.ts` directly was considered and rejected: `quiz.service.ts` is
   already ~9,700 lines with its own pre-existing lint debt, and `quiz-reminder/` (which predates
   this plan entirely) already establishes this codebase's own convention — a queue-backed,
   quiz-adjacent concern gets its own module, imported into `QuizModule`, not folded into
   `quiz.service.ts`. `quiz-reminder/` is deliberately untouched by this merge. Every file kept its
   name and content unchanged (`quiz-end.constants.ts`, `.service.ts`, `.service.spec.ts`,
   `.processor.ts`, and the `quiz-attempt-end.*` equivalents), just moved into the one shared
   directory; only the two `.module.ts` files were replaced by one `quiz-alarms.module.ts`
   registering both queues. `app.module.ts` also dropped its own redundant direct registrations of
   the two old modules - nothing outside `QuizService` ever consumed either service directly, so
   `QuizModule` importing the merged module was always sufficient. Full quiz + quiz-alarms + tasks
   + attempt-session suite (253 tests, net of the same 12 pre-existing unrelated failures) green,
   `tsc --noEmit` clean, `nest build` clean, ESLint clean (net of the same pre-existing unused-var
   debt, unchanged in count).
6. **✅ Done, 5 September 2026. Migrate the WhatsApp reminder into `src/quiz-reminder/`.** Added as
   a third step in the existing ladder (`offsetHours: 2, channel: 'whatsapp'`) alongside the two
   email steps, settling the offset at exactly 2 hours per Requirement four's recommendation
   (finding 8 - the old code's `102 minutes` read as the bug it looked like). Same two-phase
   shape as the email steps (write the ledger, then fan out sends) and the same reasoning, with a
   `MessageSend` ledger, campaign-name template lookup, and `WhatsappService.sendWhatsappMessageStrict`
   in place of `EmailSend`/Brevo - fixing findings 8 and 9 (the old loop recorded nothing and had no
   per-recipient error isolation) as a natural consequence of building it this way rather than
   porting the loop as it stood.
   **Gated behind `quiz_whatsapp_reminders_enabled`, defaulting off** - same convention as
   `src/whatsapp-reminder/` and `src/schedule-call-reminder/`, and the same reason: `MessageSend`'s
   migration is still unapplied in this dev database (confirmed via `prisma migrate status`), so
   the step is never *booked* at all while the flag is off, not merely disabled after scheduling -
   nothing half-written to repair once the migration lands and the flag flips on. The two email
   steps are unaffected either way. `QuizService.handleWhatsappReminders` (the method backing the
   still-live cron) is untouched and keeps sending in the meantime - this is additive, not a
   replacement, until the new path is verified and the flag is turned on.
   One disclosed simplification: the WhatsApp step/send jobs share `quiz-reminder`'s existing
   queue and its one rate limiter (sized for Brevo), rather than a second queue with its own
   Aisensy-sized limit the way `src/whatsapp-reminder/` runs its own at 25/s. Left shared because
   this module's WhatsApp volume is one quiz's registrants, not a daily cohort across every lead
   and enrolment - worth revisiting if that changes.
   14 new Jest tests, one guard verified by mutation. Full quiz + quiz-reminder + quiz-end +
   quiz-attempt-end suite (191 tests, net of the same 12 pre-existing unrelated failures) green,
   `tsc --noEmit` clean, ESLint clean.
   **Flag removed, 8 September 2026.** `quiz_whatsapp_reminders_enabled` and the gate in
   `scheduleForQuiz` are gone - `prisma migrate status` now shows the dev database up to date, so
   the WhatsApp step is unconditional like the two email steps. `QuizService.handleWhatsappReminders`
   and its cron call are deleted (retirement comment where they lived), since nothing else depended
   on them. Test updated: `schedules only the steps that are still in the future` now expects the
   2h whatsapp step alongside the 24h one; the two flag-toggle tests (`never books ... while its flag
   is off` / `books ... once its flag is on`) collapsed into one unconditional test.
7. **✅ Done, 5 September 2026. Switch presence to expiry-on-silence, for quiz and practice both.**
   The sweep itself is untouched and still runs alongside this (retiring it is step 8) - both
   mechanisms can pause the same stale attempt, harmlessly, during the dual-run.
   Every touch (`AttemptSessionService.setQuiz/patchQuiz/setPractice/patchPractice`) now books a
   BullMQ delayed job at "now + grace" (`staleMs`, decided at 95s per Requirement three - the
   default changed from 90s to 95s, and both the old sweep and the new job read the same value, so
   the two mechanisms cannot disagree about what "stale" means), removing whichever one it already
   had. `clearQuiz`/`clearPractice` cancel it. If touches stop, the job fires on its own and pauses
   the attempt - nothing scans anybody; the absence of a reschedule is itself the trigger. Booked
   unconditionally regardless of transport, deliberately: the job's own handler re-verifies
   `transport === 'http'` (and re-verifies `lastSeenAt`, against the one race a reschedule can't
   close - a job already mid-flight when the remove runs) before acting, rather than threading that
   check through every caller of the session methods.
   New module `src/attempt-expiry/` holds the ACTING side (re-verify + pause, needs
   `QuizService`/`PracticeService`); the BOOKING side lives directly in `AttemptSessionService`
   (`attempt-session/`), which already owns every touch. The two share one queue by name rather
   than by importing each other's module - `AttemptSessionModule` cannot import a module that
   depends on `QuizModule`/`PracticeModule` without a cycle, since both of those already depend on
   `AttemptSessionModule` (confirmed against `TasksModule`'s own import list, which combines all
   three already).
   14 new Jest tests across the two modules (booking/cancelling, the four no-op guards, the two
   pause paths), two guards verified by mutation. Full attempt-session + attempt-expiry + tasks +
   quiz + quiz-end + quiz-attempt-end + quiz-reminder + practice + auth suite (341 tests, net of
   the same 5 pre-existing unrelated failures) green, `tsc --noEmit` clean, ESLint clean.
8. **✅ Done, 5 September 2026 (partial, by design). Delete the five-second search and the sweep.**
   `handleQuizes()` bundled four behaviours with uneven readiness, so this retired only the two
   whose replacements are live and unconditional:
   - `handleEndingQuizes` and `handleExpiredDurationQuizAttempts` are **gone** - deleted from
     `QuizService`, replaced by a retirement comment where they lived (matching this file's own
     convention for fully-superseded crons). Closes entries 4, 5 and 10.
   - `handleStartingQuizes` and `handleWhatsappReminders` **stay** in `handleQuizes()` - their
     replacements (front-end step 6; the gated WhatsApp step from step 6) are not live yet.
     Deleting them now would have left waiting-room students with no `quiz-start` push and no
     client-side replacement, and no WhatsApp reminder sent at all while the new path stays off.
   - `sweepStaleAttemptSessions` is **gone outright** - its replacement (step 7) is live and
     unconditional, no such asymmetry applies. Its supporting active-session bucket index
     (`addToActiveBucket`/`getActiveBucketCandidates` in `AttemptSessionService`) is gone with it -
     nothing else read it.
   `TasksService` no longer depends on `PracticeService`/`AttemptSessionService` (only the sweep
   used them); `TasksModule` dropped the matching imports.
   Test suites updated to match: `tasks.service.spec.ts` trimmed to the two retained handlers (11
   tests → 4), the `handleExpiredDurationQuizAttempts` describe block removed from
   `quiz.service.attempt-v2.spec.ts` (its coverage lives with the alarm now, `src/quiz-alarms/`),
   and the bucket-index describe block removed from `attempt-session.service.spec.ts`. Net change:
   -16 tests. Full suite (309 tests, net of the same 5 pre-existing unrelated failures) green,
   `tsc --noEmit` clean, ESLint clean (a byproduct actually *reduced* pre-existing unused-var debt
   by 2, since deleting `handleEndingQuizes` removed dead `waitingRoomSockets`/`quizRoomSockets`
   variables along with it).
   **Update, 8 September 2026: `handleWhatsappReminders` also gone**, once its flag was removed (see
   step 6's own update above) - `handleQuizes()` now runs only `handleStartingQuizes`.
9. **Partially done, 5 September 2026, by explicit request ahead of the counters/evidence gate —
   this branch is not merged/deployed yet, so no live platform's usage was a blocker.** Removed
   every socket push that mimicked one of the three RETIRED crons'
   (`handleEndingQuizes`/`handleExpiredDurationQuizAttempts`/`sweepStaleAttemptSessions`)
   behaviour:
   - `QuizEndService.runEnd`'s `quiz-end` announce (mimicked `handleEndingQuizes`'s push) —
     removed; the close itself (the guarantee) is untouched.
   - `QuizAttemptEndService.runEnd`'s `quiz-end` announce (mimicked
     `handleExpiredDurationQuizAttempts`'s push) — removed, same treatment.
   - `QuizService.handleDurationQuizes`/`submitAfterDelay`/`delay` — deleted outright, not just
     their push. This in-process `setTimeout` pair (booked from `startQuizInternal` for a
     duration quiz on the socket transport) closed the attempt AND pushed `quiz-end`, mimicking
     `handleExpiredDurationQuizAttempts` from the other transport; `QuizAttemptEndService`
     already books the same attempt's close unconditionally regardless of transport (order-of-work
     step 5), so nothing here was still load-bearing except the now-removed push.
   `sweepStaleAttemptSessions` had no socket-push component to begin with (it only called
   `pauseQuizAttemptV2`/`pausePracticeAttemptV2`, neither of which broadcasts anything beyond the
   RPC response to the caller itself) — nothing to remove there.
   **`handleStartingQuizes`'s `quiz-start` push is explicitly out of scope here** — that cron was
   *kept*, not retired (front-end step 6 has since landed, so it may now be revisitable, but that
   is a different ask: retiring a still-live cron, not removing a push that mimics an already-dead
   one). It, and the counters/evidence gate for removing it, are unchanged.
   **Partial follow-up, 8 September 2026:** the room-membership half of `handleStartingQuizes`
   (`socketsJoin(quizRoom)` / `socketsLeave(waitingRoom)`) is commented out, not deleted — it still
   matters for group-quiz peer presence and the evidence gate for that specifically is still
   unopened, so this is deliberately reversible rather than a retirement. The `quiz-start` push and
   the cron itself are untouched, and `handleQuizes()` still runs every 5 seconds for this reason
   alone.
   `NotificationService` dropped from both services' constructors (and `NotificationModule` from
   both modules) since nothing else in either used it. 3 tests removed (2 from
   `quiz-attempt-end.service.spec.ts`, 1 from `quiz-end.service.spec.ts`) that existed solely to
   cover the now-deleted announce step; the two `make()` helpers' signatures shrank to match. Full
   quiz-end + quiz-attempt-end + quiz + tasks suite (201 tests, net of the same 12 pre-existing
   unrelated failures) green, `tsc --noEmit` clean, `nest build` clean, ESLint clean (net of the
   same pre-existing unused-var debt in `quiz.service.ts`, unchanged in count).
   **Reversed, 8 September 2026, by request: both announces are restored.** Recovered from the
   pre-migration code at commit `a7b84135` (`quiz.service.ts:7119`/`7168`, the parent of the commit
   that introduced this queue), not reconstructed from description, so the room names and payload
   shapes are exactly what `handleEndingQuizes`/`handleExpiredDurationQuizAttempts` used to send:
   - `QuizEndService.runEnd` → `/user` namespace, room `quizroom_quiz_${quizId}`, event `quiz-end`,
     payload `{ quizId }`. Fires once per quiz, after every attempt has been closed (or failed
     trying), including when there were no open attempts to close - matching the original, which
     announced unconditionally rather than only when something was actually closed.
   - `QuizAttemptEndService.runEnd` → `/user` namespace, room
     `user_platform_${userId}_${platFormId}` (the room every socket already joins on login,
     `auth.service.ts` `wsLogin`) - **not** the shared `quizroom_quiz_` room `QuizEndService` uses,
     confirmed by request: this fires once per student's own attempt, and broadcasting it to the
     whole quiz room would incorrectly tell every other student in that quiz that it had ended.
     Event `quiz-end`, payload `{ quiz: attempt.Quiz }` (the full quiz record, kept asymmetric with
     the other payload rather than unified, matching what was there before). The `Quiz` relation in
     `runEnd`'s query is now selected in full (`Quiz: true`) rather than just
     `{ timeType, duration }`, since the payload needs the whole record.
   Both announces are still best-effort and strictly after the close, per Requirement two's
   close-then-announce split: each is its own try/catch, logged and swallowed on failure, so a
   socket/Redis hiccup can never turn into a retried close. `NotificationModule` is back in
   `quiz-alarms.module.ts`'s imports. 5 new Jest tests (3 in `quiz-end.service.spec.ts`, 3 in
   `quiz-attempt-end.service.spec.ts`, one of which asserts nothing is announced when the job was
   a no-op) - not merely restoring the 3 removed above, since the per-student room decision and the
   failure-isolation behaviour are new coverage, not old coverage restored. Full quiz-alarms suite
   (42 tests) green, `tsc --noEmit` clean, ESLint clean.
10. **Done, 8 September 2026, by request: the `quiz-start` push migrated onto a BullMQ job too.**
    Searched first for an existing method that already books something at `Quiz.startTime` (per an
    explicit "do not write a new method for this without checking" instruction) - none exists;
    `QuizReminderService`'s ladder is the closest generic "something relative to startTime"
    machinery, but it is built for ledgered per-recipient sends (`EmailSend`/`MessageSend`), not a
    live socket broadcast, so reusing it would mean bending a send pipeline into a push mechanism.
    **Folded into `QuizEndService`/`QuizEndProcessor` on the existing `quiz-end` queue, by
    request** - a start alarm and an end alarm are the same "per-quiz moment" shape, and a third
    module/queue/processor for one more push was not warranted. `QuizEndProcessor.process` routes
    on `job.name` (`QUIZ_END_JOB` vs. the new `QUIZ_START_JOB`) to `runEnd`/`runStart`, both now on
    `QuizEndService`.
    **Scope, by request: every quiz with a `startTime`, regardless of `timeType`** - matching
    `handleStartingQuizes`' cron exactly (it never filtered on `timeType` either), not
    `QuizEndService`'s own fixed-window-only scope. `scheduleStartForQuiz`/`removeStartForQuiz`
    mirror `scheduleForQuiz`/`removeForQuiz`'s shape; `reconcile()` now does both queries and
    returns `{ quizzesConsidered, startsConsidered }` (was `{ quizzesConsidered }` only - the one
    breaking change, one existing test updated for the new shape).
    `runStart` restores `handleStartingQuizes`' push exactly (commit a7b84135,
    `quiz.service.ts:7095` pre-migration) - `/user` namespace, room `waitingroom_quiz_${quizId}`,
    payload `{ quizId }` - as a courtesy with no database guarantee, so its own failure is logged
    and swallowed rather than retried. **The room reassignment
    (`socketsJoin(quizRoom)`/`socketsLeave(waitingRoom)`) is deliberately NOT part of this
    migration** - it stays commented out at its one remaining call site in
    `QuizService.handleStartingQuizes`, pending the same "counters/evidence gate" as before; moving
    the push to a queue and re-enabling the room move are two different asks.
    Wired into the same call sites as the other per-quiz alarms - `adminCreateQuiz`,
    `adminUpdateQuiz` (via a new `scheduleQuizStartAlarm` wrapper in `QuizService`, matching
    `scheduleQuizEndAlarm`'s own shape) and `adminDeleteQuiz` (`removeStartForQuiz`).
    15 new Jest tests in `quiz-end.service.spec.ts` (`scheduleStartForQuiz`, `removeStartForQuiz`,
    `runStart`, plus the `reconcile()` test rewritten for the two-query shape). Full quiz-alarms
    suite (57 tests) green, `tsc --noEmit` clean, ESLint clean (net of the same pre-existing debt,
    unchanged in count).
    **The dual-run ended the same day, by request: `handleQuizes` and `handleStartingQuizes` are
    both deleted, 8 September 2026.** `handleQuizes` had already been trimmed to this one method
    (step 8/9's updates above); with the push migrated onto `QuizEndService.runStart`, nothing was
    left to dual-run for. The room reassignment (`socketsJoin(quizRoom)`/`socketsLeave(waitingRoom)`)
    goes with the method rather than anywhere else - it was already commented out, and its
    "counters/evidence gate" is still unopened; recovering it means reading git history at this
    commit, not searching a live call site. `TasksService` no longer depends on `QuizService`
    (`QuizModule` dropped from `tasks.module.ts`); `findSockets` in `QuizService` is now unused
    (its only caller was this method) but was left in place - deleting it was not part of this ask.
    Retirement comments in both `tasks.service.ts` (where the cron lived) and `quiz.service.ts`
    (where the method lived) cross-reference each other and this entry. Full
    tasks + quiz + quiz-alarms + quiz-reminder suite (224 tests, net of the same 12 pre-existing
    unrelated failures) green, `tsc --noEmit` clean, ESLint clean (15 pre-existing unused-var
    errors, one fewer than before - `waitingRoomSockets` went with the method it lived in).
    **Future cleanup, not yet due:** `QuizEndService.runStart`'s `quiz-start` emit and
    `QuizEndService.runEnd`/`QuizAttemptEndService.runEnd`'s `quiz-end` emits (restored earlier in
    this same order-of-work step) should be deleted once no platform's frontend depends on the
    `quiz-start`/`quiz-end` socket events for the quiz workflow any more - i.e. once the
    client-side countdown/polling replacement (front-end step 6 and whatever end-of-quiz handling
    replaces the `quiz-end` listener) has landed on every platform, not just `LMS_V2`. Until that is
    confirmed across platforms, the emits stay as a courtesy for whichever client is still listening.

The team already has a good completion test for this line of work: the scheduling package being
uninstalled is the proof it is finished. This plan removes the last two quiz reasons it is still
installed; what stands behind them is the disabled newsletter module, which is separate work.

---

## The five decisions, answered

Answered 5 September 2026. Each is recorded with what it commits the build to.

**1. When a student's connection drops during a duration quiz, does their clock stop?**
**The clock never stops.** No pause credit, no time returned for an outage. A genuine connectivity
problem is a support case, not a timer feature.
*Consequence:* this is already how `handleExpiredDurationQuizAttempts` behaves — it computes the
deadline as `attempt.createdAt + duration` and ignores pauses entirely — but it contradicts the
pause path, which stops the clock today. The two disagree right now about what a duration attempt's
deadline is. Implementing this means auditing how `timeTaken` and accrued time are written on pause
and resume, and making the pause path agree with the sweep rather than the other way round.

**2. How long offline before it counts as leaving?**
**No offline mode to design for** — every quiz action is an HTTP request, and a failed request
raises a toast. The server-side numbers are still needed, and are set in Requirement three:
**30-second check-in, 95-second grace**, chosen as three missed check-ins plus slack rather than
inherited from a sweep cadence. `attemptSessionStaleMs` is already the knob.
*Consequence:* the grace must not be tightened until the check-in moves off the main thread
(front-end step 2), or finding 6 starts pausing healthy attempts.

**3. Do group quizzes keep live peer presence?**
**Skipped for now.** Presence keeps its socket, unchanged and untouched by this work.
*Consequence:* the socket does not go away at the end of this plan. Front-end step 7 deletes the
quiz *push* listeners and the transport branch, not the connection. The win here is reliability and
the two crons, not removed infrastructure.

**4. Answers given while offline — replay them, or drop them?**
**Dropped.** No replay queue, no pending-answer state. A failed answer request surfaces as a toast
and is not stored; the deadline is enforced server-side and nothing is accepted after it.
*Consequence:* the old front-end step 7, "surviving a dropped connection", is gone entirely and the
steps after it have renumbered. The toggle-off hazard it described is not gone — it moves from the
replay code to the student, and is now a display requirement in step 4.

**5. Does "away from sockets" mean quizzes only, or everything?**
**Quizzes only**, minus presence per decision 3. Chat, notifications and calling keep the
connection and are separate work.

---

Written after reading both repositories on 3 September 2026. Decisions recorded, WhatsApp reminder
and practice attempts brought into scope, and offline replay removed, on 5 September 2026.
