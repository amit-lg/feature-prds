# Socket Microservice Migration Spec

**Purpose of this document**: a self-contained brief for a *new, separate* NestJS project ("**growth-socket**") that will own the Socket.IO server currently embedded in GrowthCommand (`src/employee/employee.gateway.ts`, `src/user/user.gateway.ts`, `src/command/command.gateway.ts`, `src/main-gateway/`). Paste this whole file into the new project and use it as the spec for building every socket endpoint there.

**Why**: today the Socket.IO server runs inside the same NestJS process as the REST API. Every deploy of GrowthCommand kills the process and drops every open socket (call signaling, live quiz sessions, chat, device connections). Splitting the socket server into its own always-running process means redeploying the API no longer disconnects anyone. This mirrors the pattern GrowthCommand already uses for **`src/geo/`** (a local module that talks to a separately-deployed service over RabbitMQ) — but sockets need a two-way version of that pattern, described below.

### Implementation status in this repo (GrowthCommand side)

Already wired, so this repo is ready to connect to growth-socket as soon as it exists:

- **Channel 2 (outbound, §5) is fully switched over — no local-emit fallback.** `src/notification/notification.module.ts` registers a `SOCKET_SERVICE` RMQ client (`ClientsModule.registerAsync`, queue `socket_events_queue`, same shape as `GeoModule`/`GEO_SERVICE`). `src/notification/notification.service.ts`'s `sendNotification()` now does `this.socketClient.emit('socket.notify', { namespace, room, event, data, exceptRoom })` instead of touching a local `Server`. **Until growth-socket is deployed and consuming `socket_events_queue`, none of the ~130 business-logic notifications in §5.1 will reach any connected client** — this was a deliberate choice (full switch, not dual-mode) made when this migration started. `NotificationService.server`/`setServer()` were kept as-is; they're only used by the local-relay call sites (`chat_typing` in `employee.gateway.ts`, the 4 WebRTC handlers in `command.gateway.ts`) that intentionally never leave this process — see §4.1/§4.3.
- **Channel 1 (inbound RPC, §4) is infrastructure-only — no handlers yet.** `src/main.ts` now also calls `app.connectMicroservice(...)` for `employee_socket_queue`, `user_socket_queue`, and `command_socket_queue` (alongside the pre-existing `main_queue`), so growth-socket can already open RPC connections. `src/socket-rpc/socket-rpc.module.ts` registers three empty controllers — `EmployeeSocketRpcController`, `UserSocketRpcController`, `CommandSocketRpcController` — one per queue, each with a comment pointing at the relevant event table below. Add `@MessagePattern('<namespace>.<event>')` methods to these as each namespace cuts over per §8; until then, calls to these queues get no response (matches how `main_queue` has always behaved — zero handlers is a valid, inert state, not a crash).
- Nothing has been deleted yet: the embedded `/employee`, `/user`, `/command`, and root gateways, and `MainGatewayGateway`, are all still present and still accept direct client connections exactly as before. Only the outbound-notification *delivery mechanism* changed.

---

## 1. Current state (GrowthCommand, for context)

- NestJS 11, hybrid app: HTTP (Express) + one RMQ microservice listener (`main_queue`, currently has **zero** `@MessagePattern`/`@EventPattern` handlers — dead scaffolding) + Socket.IO with a Redis adapter for cross-instance fan-out.
- Bootstrap order (`src/main.ts`):
  ```ts
  const app = await NestFactory.create(AppModule);
  app.enableCors();
  app.connectMicroservice<MicroserviceOptions>({
    transport: Transport.RMQ,
    options: { urls: [process.env.rabbitmq || 'amqp://localhost:5672'], queue: 'main_queue', queueOptions: { durable: false } },
  });
  await app.startAllMicroservices();
  const redisIoAdapter = new RedisIoAdapter(app);
  await redisIoAdapter.connectToRedis();
  app.use(bodyParser.urlencoded({ extended: true }));
  app.use(bodyParser.json());
  app.useWebSocketAdapter(redisIoAdapter);
  app.setGlobalPrefix('api');
  await app.listen(process.env.port);
  ```
- Four Socket.IO gateways today, all in-process:
  - Root namespace (`MainGatewayGateway`) — exists only to capture the raw `Server` instance into `NotificationService`; force-disconnects anything that connects to it directly.
  - `/employee` — call-center/CRM/LMS-admin app.
  - `/user` — student/learner app (quizzes, practice, chat, course watch).
  - `/command` — WebRTC call signaling + employee device permission pushes.
- **Emit pattern**: any service in the app injects `NotificationService` and calls `sendNotification(namespace, room, event, data, exceptRoom?)`, which does `server.of(namespace).to(room).except(exceptRoom).emit(event, data)` on the single shared `Server` instance. ~130 call sites across 13 service files use this.
- **Redis adapter** (`src/common/utils/redis-server-adapter.utils.ts`):
  ```ts
  export class RedisIoAdapter extends IoAdapter {
    private adapterConstructor: ReturnType<typeof createAdapter>;
    async connectToRedis(): Promise<void> {
      const pubClient = createClient({ url: process.env.redis });
      const subClient = pubClient.duplicate();
      await Promise.all([pubClient.connect(), subClient.connect()]);
      this.adapterConstructor = createAdapter(pubClient, subClient);
    }
    createIOServer(port: number, options?: ServerOptions): any {
      const server = super.createIOServer(port, {
        ...options,
        cors: { origin: '*', methods: ['GET', 'POST', 'OPTIONS'], allowedHeaders: ['Content-Type', 'Authorization', 'dauth'], credentials: true },
      });
      server.adapter(this.adapterConstructor);
      return server;
    }
  }
  ```
- Auth on every gateway is done **imperatively** inside `handleConnection` (DB lookup of `Platform` by `dauth` header/query/origin) — there is no `@UseGuards` on any gateway. Per-employee/per-user identity (`client.employeeId` / `client.userId`) is only established later, via a `login` socket event, not at connect time.
- On the employee side, **socket room membership doubles as an authorization mechanism**: on login, the server resolves the employee's permission tree and does `client.join(permissionName)` for every permission (e.g. `canViewLeads`, `EmployeeAdd`). Handlers later check `client.rooms.has('EmployeeAdd')` instead of hitting the DB again. This must be preserved exactly.

## 2. The reference pattern: `src/geo/` (RabbitMQ, request/response)

This is the pattern to imitate, extended to be bidirectional (geo is one-directional: GrowthCommand only ever calls out to Geo, and Geo never calls back).

`src/geo/geo.module.ts`:
```ts
@Module({
  imports: [
    ConfigModule,
    ClientsModule.registerAsync([
      {
        name: 'GEO_SERVICE',
        imports: [ConfigModule],
        inject: [ConfigService],
        useFactory: (config: ConfigService) => ({
          transport: Transport.RMQ,
          options: {
            urls: [config.get<string>('rabbitmq') || 'amqp://localhost:5672'],
            queue: 'geo_queue',
            queueOptions: { durable: false },
          },
        }),
      },
    ]),
  ],
  controllers: [GeoController],
  providers: [GeoService],
  exports: [GeoService],
})
export class GeoModule {}
```

`src/geo/geo.service.ts` (client-side call wrapper — reuse this shape for the new RPC client):
```ts
@Injectable()
export class GeoService implements OnModuleInit {
  constructor(@Inject('GEO_SERVICE') private readonly geoClient: ClientProxy) {}
  async onModuleInit() { await this.geoClient.connect(); }

  private async send<T = any>(pattern: string, data: any = {}): Promise<T> {
    try {
      const result = await firstValueFrom(this.geoClient.send<T>(pattern, data).pipe(timeout(10000)));
      if (result && typeof result === 'object' && 'success' in result) {
        const envelope = result as any;
        if (!envelope.success) throw new HttpException(envelope.message || 'error', HttpStatus.NOT_FOUND);
        return envelope.data;
      }
      return result;
    } catch (error) {
      if (error instanceof HttpException) throw error;
      throw new HttpException(error.message || 'service unavailable', HttpStatus.SERVICE_UNAVAILABLE);
    }
  }
}
```

Key conventions to copy:
- `ClientsModule.registerAsync` (not `.register`), string injection token, config pulled from `ConfigService`.
- `queueOptions: { durable: false }` on every queue in this codebase (flag: not production-durable — consider `durable: true` for the new service if message loss on broker restart is unacceptable, since call-signaling/lead-routing events matter more than geo lookups).
- No custom exchange — default direct exchange, plain queue name.
- Explicit `.connect()` in `onModuleInit()`.
- Response envelope convention: `{ success: boolean, data: T, message?: string }`. **Reuse this envelope for every RPC response in the new contract below.**
- `timeout(10000)` on every RPC call via rxjs — reuse this.
- Message pattern strings are plain dot-namespaced literals with no shared enum between the two services (implicit contract, matched only by convention) — for this migration we define the full pattern list explicitly in §4/§5 below so both sides can be typed against the same list.
- `.env`: `rabbitmq = amqp://localhost:5672` (note: lowercase key, no schema validation — env vars are read directly via `process.env`).
- Deps already present in GrowthCommand's `package.json` that the new project also needs: `@nestjs/microservices`, `amqplib`, `amqp-connection-manager`, `socket.io`, `@nestjs/websockets`, `@nestjs/platform-socket.io`, `@socket.io/redis-adapter`, `redis`, `ioredis`.

## 3. Target architecture

```
┌─────────────────────┐          ┌──────────────────────────┐
│  Browser / mobile    │  WS      │   growth-socket           │
│  clients (employee,  │◄────────►│   (new project)           │
│  user, command apps)  │          │   - owns Socket.IO server │
└─────────────────────┘          │   - Redis adapter          │
                                  │   - connection/auth/rooms  │
                                  └──────────┬────────────────┘
                                             │ RabbitMQ (2 channels, see §4/§5)
                                             ▼
                                  ┌──────────────────────────┐
                                  │   GrowthCommand (main app) │
                                  │   - all business logic     │
                                  │   - Prisma / DatabaseService│
                                  │   - unchanged DTOs/validation│
                                  └──────────────────────────┘
```

**Design principle: growth-socket is a dumb relay, not a second brain.** It does not duplicate business logic, DTOs, or validation. Every inbound client event is forwarded to GrowthCommand as an RMQ RPC call; the response envelope is relayed back to the client verbatim. GrowthCommand keeps its existing `ValidationPipe`/DTO/service code unchanged — those bodies just move from `@SubscribeMessage` handlers into `@MessagePattern` handlers with identical logic. This minimizes duplicated business logic and means the new project barely needs to know what each payload *means*, only how to move it.

The one place growth-socket needs real logic is **connection-time auth + room joins**, because rejecting bad connections before an RMQ round-trip is worth the extra complexity, and because socket room membership (esp. on `/employee`) doubles as authorization state that must live where the sockets live. Two options — pick one:

- **Option A (recommended, consistent with CLAUDE.md's "single injectable DB access point"):** growth-socket has *no* direct DB access. `handleConnection` makes an RPC call (`platform.resolveForSocket`, `device.registerForSocket`, etc.) to GrowthCommand, which does the existing Prisma lookups and returns `{ platformId, roomsToJoin: string[], sessionContext }`. Costs one extra RMQ round-trip per connect (acceptable — connects are far rarer than events).
- **Option B:** growth-socket gets its own read-only Prisma client (import the committed `src/generated/prisma` client from GrowthCommand, or generate its own from a copy of `prisma/schema.prisma`) and does the `Platform`/`PlatformOptions`/`EmployeeDevices`/`UserDevice` lookups itself. Faster (no round-trip) but creates schema drift risk and duplicates DB credentials/access into a second service.

This document specs both channels assuming **Option A**; if you choose Option B, only §6 (connection flows) changes — §4/§5 (event relay) are identical either way.

## 4. Channel 1 — Socket → Main App (RPC, request/response)

Every inbound `@SubscribeMessage` in the current gateways becomes an RMQ message pattern that growth-socket calls and GrowthCommand answers.

- **New queue in GrowthCommand**: `socket_rpc_queue` (or split per namespace — `employee_socket_queue`, `user_socket_queue`, `command_socket_queue` — recommended, so each namespace's handlers live in their own Nest microservice controller, mirroring the existing module boundaries).
- **Pattern naming convention**: `<namespace>.<event-name>`, e.g. `employee.login`, `user.watch-course`, `command.call`.
- **Request payload shape** (growth-socket → main app), always:
  ```ts
  {
    session: {
      employeeId?: number;   // present once logged in, /employee and /command
      userId?: number;       // present once logged in, /user
      platformId: number;    // always present after handleConnection
      deviceId?: number;
      attendanceId?: number;
      breakId?: number;
      quizAttempt?: { quizId?: number; attemptId?: number; questionId?: number };
      practiceAttempt?: { ... };
      socketId: string;      // client.id, for logging/targeted replies if ever needed
    },
    payload: any;             // whatever the client sent as the event's data — pass through untouched
  }
  ```
- **Response envelope** (main app → growth-socket), same convention as geo:
  ```ts
  { success: boolean; data?: any; message?: string; event?: string }
  ```
  GrowthCommand's handler emits `data` back to the client under the **success event name** from the table below; on `success:false` (or RPC timeout/error), growth-socket emits `data`/`message` under the **error event name** from the table below. This reproduces today's `try { ...; client.emit(successEvent, x) } catch { client.emit(errorEvent, err) }` pattern exactly, just moved server-side of the RPC boundary — growth-socket's relay code is fully generic per event, driven by a config table (see §7).
- GrowthCommand side: register a second hybrid microservice connection in `main.ts` (same `app.connectMicroservice` call, new queue name(s)), and add `@Controller()` classes with `@MessagePattern('employee.login')` etc. that call the *exact same* `EmployeeService`/`LeadService`/`QuizService`/... methods the gateways call today — no logic changes, just a new entry point.

### 4.1 Full inbound event table — `/employee` namespace (39 events)

RPC pattern = `employee.<event>` unless noted.

| Client event | Payload (pass through) | Success event | Error event | Notes |
|---|---|---|---|---|
| `logout` | none | — | — | cleanup, no reply |
| `newInteractionCall` | any | — | — | |
| `saveInteractionCall` | any | — | — | |
| `getlead` | `{ leadCount }` (cap 50) | (leads pushed via existing emit, no direct reply) | — | |
| `attendance` | `{ date }` | — | — | |
| `login` | `{ email, password }` | `loginsuccess`, `onlineEmployees`, `employeepermissions` (3 emits) | `loginError` | Also triggers `roomsToJoin` — see §6.2; online-presence dedupe check against room `online_employee` |
| `getCourse` | any | — | — | |
| `getCourseMeta` | `{ courseId }` (int>0) | — | `getCourseMetaError` | |
| `addCourseMeta` | `AddCourseMeta` DTO | — | `loginError` (mislabeled in source — keep as-is) | |
| `addCourse` | `AddCourseDto` | — | `loginError` (mislabeled) | |
| `getUser` | none | — | — | |
| `getLeadsDropDownContent` | none | — | — | |
| `employeeBreak` | none | — | — | |
| `getClasses` | none | — | — | |
| `checkForBreak` | none | `break` | — | |
| `getHierarchy` | any | `hierarchy` | — | |
| `employeeDetails` | none | — | — | |
| `addEmployee` | any (`CreateEmployeeDto`) | `employeeCreated` | `employeeCreateError` | Gate: caller must hold room `EmployeeAdd` — see §6.2 authorization-via-room-membership |
| `giveDevice` | none | — | — | |
| `allowDevice` | `EmployeeDeviceAllowChangeDto` | — | `getPaymentsError` (mislabeled) | |
| `allowEmployeeToDevice` | `EmployeeToDeviceAllowDto` | — | `allowEmployeeToDeviceError` | |
| `changeDeviceType` | `ChangeDeviceTypeDto` | — | `changeDeviceTypeError` | |
| `requestUSB` | none | — | — | |
| `openUSB` | `UnlockUSBDto` | — | `unlockDeviceUSBError` | |
| `changeDeviceName` | `ChangeEmployeeDeviceNameDTO` | — | `changeDeviceNameError` | |
| `unlockUSB` | raw password string | — | — | |
| `getLeadInfo` | `{ leadId }` | — | — | |
| `getCallingNumber` | none | — | — | |
| `SetCallingNumber` | `{ callingNumberId, interactionType }` | — | — | |
| `giveScheduledCalls` | none | — | — | |
| `leadCourseChange` | `{ leadId, courseId }` | — | — | |
| `campaignData` | `CampaignGetDto` | — | `campaignDataError` | |
| `giveScheduledSelfCalls` | none | — | — | |
| `leadCallStart` | `{ interactionId, phoneId }` | — | — | |
| `leadCallAgain` | `{ interactionId }` | — | — | |
| `leadCallPicup` | `{ interactionId }` | — | — | |
| `leadNotConnected` | `{ interactionId }` | — | — | |
| `leadSource` | any | — | — | |
| `callingEmployee` | none | — | — | |
| `leadCallEnd` | `{ interactionId }` | — | — | |
| `leadSave` | `LeadStatusDto` | — | `leadSave-error` | |
| `searchLead` | `{ searchText }` | — | — | |
| `leadMessage` | any | — | — | |
| `getUserForm` | none | — | — | |
| `getUserFormDetails` | `GetFormDataDto` | — | `leadSave-error` (mislabeled) | |
| `getFollowUps` | none | — | — | |
| `getPlatforms` | any | — | — | |
| `getPlatformPermission` | any | — | — | |
| `getSelfPlatformPermission` | `{ platformId }` (int>0) | — | `getSelfPlatformPermissionError` | |
| `setPlatformPermission` | `{ platformId, permission }` | — | `setPlatformPermissionError` | |
| `getSelfPlatformGroups` | `{ platformId }` | — | `getSelfPlatformGroupsError` | |
| `getAllPlatformGroups` | any | — | — | |
| `createPlatformGroup` | `{ groupName }` | — | `createPlatformGroupError` | |
| `addPlatformToGroup` | `{ groupId, platformId }` | — | `addPlatformToGroupError` | |
| `getFirstFollowUp` | `{ leadCount }` (cap 50) | — | — | |
| `getSecondFollowUp` | `{ leadCount }` (cap 50) | — | — | |
| `getThirdFollowUp` | `{ leadCount }` (cap 50) | — | — | |
| `leadStat` | `LeadStatDTO` | — | `getLeadStatsError` | |
| `marketing-lead-stats` | `GetMarketingLeadStatsDto` | — | `marketing-lead-stats-error` | |
| `marketing-utm-lead-stats` | `GetMarketingLeadStatsDto` | — | `marketing-lead-stats-error` | |
| `leadEmployeeStat` | `LeadStatDTO` | — | `leadEmployeeStatError` | |
| `leadBySource` | `LeadStatDTO` (whitelist) | — | `leadSourceStatsError` | |
| `leadByInteraction` | `LeadStatDTO` (whitelist) | — | `leadByInteractionError` | |
| `chat_typing` | `{ roomId, status }` | *(fire-and-forget broadcast, not a reply — see §6.3)* | — | growth-socket can handle this **locally**, no RPC needed: just `server.of('/employee').to('chat_room_'+roomId).emit('typing', { employeeId, roomId, status })` |

Where "Success event" is blank, the handler doesn't emit a synchronous reply — the real payload arrives later via an async `sendNotification` push (see §5). In those cases the RPC call can be **fire-and-forget** (`geoClient.emit(pattern, req)` instead of `.send(...)`) rather than request/response, saving a round trip. Recommend auditing each blank-reply row against `src/employee/employee.service.ts`/`src/lead/lead.service.ts` to confirm before wiring as emit vs send.

### 4.2 Full inbound event table — `/user` namespace (26 events)

RPC pattern = `user.<event>` unless noted. Every handler below (except `identify` and `disconnect-call`) guards on `client.userId` being set (i.e. logged in) before calling the service — reproduce that guard check inside growth-socket using `session.userId` so unauthenticated calls fail fast without an RMQ round trip.

| Client event | Payload | Success/behavior | Error event |
|---|---|---|---|
| `call-start-offer` | `{ to, offer }` | relayed via `sendNotification('/user', to, 'call-start-offer', offer)` — **handle locally in growth-socket, no RPC** (see §6.3) | — |
| `call-answer-offer` | `{ to, offer }` | same, local relay, event `call-answer-offer` | — |
| `identify` | `{ identify: string }` | `client.join(identify)` — **local only, no RPC**. Unauthenticated: any client may join any room string. | — |
| `call-ice-candidate` | `{ to, candidate }` | local relay, event `call-ice-candidate` | — |
| `disconnect-call` | `{ to }` | local: `client.to(to).emit('call-ended', data)` — **local only** | — |
| `watch-course` | `{ courseId }` (tolerant of JSON-string) | — | `watch-course-error` |
| `add-practice-question-difficulty` | `AddQuestionDifficultyDto` | — | `add-practice-question-difficulty-error` |
| `quiz-user-cheating` | `{ offense }` | — | `quiz-user-cheating-error` |
| `login` | `{ token }` | JWT verified server-side; sets `session.userId/platformId/token` — see §6.2 | `login-error` |
| `make-practice-attempt` | `PracticeAttemptCreateDto` | — | `make-practice-attempt-error` |
| `get-practice-parent-question` | `{ questionId }` | — | `get-practice-parent-question-error` |
| `watch-practice-question` | `{ questionId }` | — | `watch-question-error` |
| `add-option-practice-question` | `{ questionId, optionId }` | — | `add-option-practice-question-error` |
| `unregister` | none | no-op besides userId guard | `unregister-error` |
| `get-practice-question-explaination` | `{ questionId }` | — | — |
| `submit-practice-attempt` | none | — | `submit-practice-attempt-error` |
| `pause-practice-attempt` | none | — | `pause-practice-attempt-error` |
| `get-quiz-parent-question` | `{ questionId }` | — | `get-quiz-parent-question-error` |
| `make-quiz-attempt` | `QuizAttemptCreateDto` | — | `make-quiz-attempt-error` |
| `give-quiz-questions` | none | requires `session.quizAttempt.{quizId,attemptId}` | `give-quiz-questions-error` |
| `watch-quiz-question` | `{ questionId }` | requires `quizAttempt.attemptId` | `watch-quiz-question-error` |
| `add-essay-practice-question` | `{ essay }` | — | `add-essay-practice-question-error` |
| `mark-essay-practice-question` | `{ isCorrect }` | — | `mark-essay-practice-question-error` |
| `add-option-quiz-question` | `{ optionId }` | requires `quizAttempt.{attemptId,questionId}` | `add-option-quiz-question-error` |
| `add-essay-quiz-question` | `{ essay }` | — | `add-essay-quiz-question-error` |
| `get-quiz-question-explaination` | none | requires `quizAttempt.attemptId` | `get-quiz-question-explaination-error` |
| `submit-quiz-attempt` | none | requires `quizAttempt.attemptId` | `submit-quiz-attempt-error` |
| `mark-essay-quiz-question` | `{ isCorrect }` | — | `mark-essay-quiz-question-error` |
| `pause-quiz-attempt` | none | requires `quizAttempt.attemptId`; calls the *disconnect* handler intentionally (reused) | `pause-quiz-attempt-error` |
| `add-quiz-question-difficulty` | `AddQuizQuestionDifficultyDto` | — | `add-quiz-question-difficulty-error` |

Note: `/user` has its own independent WebRTC signaling (`call-start-offer`/`call-answer-offer`/`call-ice-candidate`/`disconnect-call`/`identify`) that is completely separate from `/command`'s signaling (`call`/`answer`/`ice_candidate`/`disconnect_call`) — two parallel systems, don't merge them.

### 4.3 Full inbound event table — `/command` namespace (4 events)

All four are pure relays — **handle entirely inside growth-socket, no RPC call needed at all**:

| Client event | Payload | Behavior |
|---|---|---|
| `call` | `{ to, from }` | `server.of('/command').to(to).emit('incoming_call', data)` |
| `answer` | `{ to, from }` | `server.of('/command').to(to).emit('call_answered', data)` |
| `ice_candidate` | `{ to, candidate }` | `server.of('/command').to(to).emit('ice_candidate', candidate)` |
| `disconnect_call` | `{ from }` | `server.of('/command').to(from).emit('call_ended', data)` |

These are unauthenticated room-targeted relays today (no validation that `to`/`from` is a real employee/room) — preserve that behavior unless you want to tighten it as part of this migration (flag to product owner; not in scope of a like-for-like migration).

## 5. Channel 2 — Main App → Socket Service (event publish, fire-and-forget)

Today, ~130 call sites across 13 files call `notificationService.sendNotification(namespace, room, event, data, exceptRoom?)`, which does `server.of(namespace).to(room).except(exceptRoom).emit(event, data)` on an in-process `Server`. After the split, this must go over RabbitMQ instead.

- **New queue**: `socket_events_queue`. GrowthCommand becomes an RMQ **client** here (like `GeoModule`/`GeoService`), growth-socket becomes the **consumer**.
- **GrowthCommand side change**: rewrite `src/notification/notification.service.ts` so `sendNotification` publishes instead of touching a local `Server`:
  ```ts
  @Injectable()
  export class NotificationService implements OnModuleInit {
    constructor(@Inject('SOCKET_SERVICE') private readonly socketClient: ClientProxy) {}
    async onModuleInit() { await this.socketClient.connect(); }

    sendNotification(namespace: string, room: string, event: string, data: any, exceptRoom = '') {
      this.socketClient.emit('socket.notify', { namespace, room, event, data, exceptRoom });
    }
  }
  ```
  Register `SOCKET_SERVICE` via `ClientsModule.registerAsync` exactly like `GEO_SERVICE`, new queue `socket_events_queue`. This is a **drop-in replacement** — none of the ~130 call sites change, since they all go through this one method. `MainGatewayGateway`'s role (capturing `server` into `NotificationService`) disappears entirely — delete `MainGatewayGateway`/`main-gateway` module, since there's no longer a local `Server` to capture.
- **growth-socket side**: a microservice controller with one `@EventPattern('socket.notify')` handler:
  ```ts
  @EventPattern('socket.notify')
  handleNotify(@Payload() msg: { namespace: string; room: string; event: string; data: any; exceptRoom?: string }) {
    this.server.of(msg.namespace).to(msg.room).except(msg.exceptRoom || '').emit(msg.event, msg.data);
  }
  ```
  where `this.server` is the raw Socket.IO `Server` instance (captured the same way `MainGatewayGateway.afterInit` does today — keep one lightweight root-namespace gateway in growth-socket purely to grab `server` on init, or use `@WebSocketGateway()` directly on the controller/service that owns this handler).

### 5.1 Full outbound emit inventory (reference — do not need to individually re-implement; all flow through the one `socket.notify` handler above)

Grouped by source file, namespace, room pattern, event. All are already `{namespace, room, event, data, exceptRoom?}` shaped and require no code changes beyond §5's `NotificationService` rewrite.

**`employee.service.ts`** (`/employee`): rooms `online_employee` (`cameOnline`), `canViewDevice` (`employeeLogin`, `onlineDevice`), `canViewLeads` (`callingNumbersChangedOut`), `online_employee` (`employeelogout`).

**`device.service.ts`** (`/employee`): rooms `canViewDevice` (`onlineDevice`, `deviceAllowedChanged`, `unlockedUSB`, `employeeToDeviceAllowedChanged`, `deviceTypeChanged`, `deviceNameChanged`), `DeviceView` (`deviceNotAllowed`), `employee-device-<id>` (`deviceSelfAllowedChanged`, `unlockUSB`, `employeeToDeviceSelfAllowedChanged`, `deviceSelfTypeChanged`, `deviceSelfNameChanged`), `canUSBOpen` (`requestUSBOpen`), `canAllowDevice` (`requestAllowDevice`), `canAllowEmployeeToDevice` (`requestAllowEmployeeToDevice`).

**`courier.service.ts`** (`/employee`): room `canViewDevice`, event `employeeToDeviceAllowedChanged`.

**`lead.service.ts`** (`/employee` + `command` namespaces): `/employee` room `employeeLeadWatching-<leadId>` (`otherInteractionDone`, `otherInteractionCall`, `lead-change-enquiry`, `newSignedUpLeadChange`), `/employee` room `canViewClasses` (`callingNumbersChanged`), `command` namespace room `employee-device-<deviceId>-phone` (`makeCall`, `pickCall`, `endCall`), `command` room `employee-device-<employeeId>-phone` (`leadCallStart`).

**`communicate.service.ts`** (`/user`, chat/friends): rooms `chat_room_<id>` and `user_platform_<userId>_<platformId>` — events `user_online`, `user_offline`, `new_friend_request`, `respond_friend_request`, `new_chat_room`, `new_message_recieved`, `new_message_edited`, `new_message_deleted`, `poll_vote_deleted`, `poll_vote_updated`, `reaction_created`/`updated`/`deleted`, `message_viewed`, `all_messages_read`, `typing_status_updated`.

**`discussion.service.ts`** (dual-emit `/user` + `/employee`, same room/event, some with `exceptRoom`): rooms `watching_discussion_<id>`, `watching_poll_<id>` — events `new-comment`, `update-comment`, `delete-comment`, `poll-option-change`, `comment-poll-option-change`.

**`payment.service.ts`** (`/user`): room `user_platform_<userId>_<platformId>`, event `user_enrolled`.

**`ticket.service.ts`**: `/employee` room `ticket_queue_<platformId>` event `new_ticket`; `/user` + `/employee` room `chat_room_<chatroomId>` event `ticket_status_changed`.

**`platform.service.ts`**: `/user` dynamic room, events `learn-mate-user-updated`/`learn-mate-room-created` (with `exceptRoom: user_<userId>`); `/user` room `user_device__platform_8_<deviceId>` event `device-unregistered` (⚠ hardcoded platform id `8` — pre-existing bug, flag but don't silently "fix" during migration); `/employee` room `canViewGroups` event `platformGroupAdded`.

**`quiz.service.ts`** (`/user`, live quiz presence): rooms `liveroomstring`, `quiz_<quizId>_<groupId>`, `groupRoom`, dynamic `room`, `currentRoom`, `waitingRoom`, `quizRoom` — events `went-offline`, `came-online`, `watching-question`, `updated-question-option`, `quiz-submit-attempted`, `quiz-attempt-submitted`, `quiz-start`, `quiz-end`. Also one **non-emit** call: `server.of('/user').socketsLeave(waitingRoom)` — this is a direct server method, not `sendNotification`; growth-socket needs a second `@EventPattern` (e.g. `socket.socketsLeave`) for this one case, or fold it into `socket.notify` with a `kind: 'emit' | 'socketsLeave'` discriminator.

**`command.service.ts`** (`/employee`, `/user`, `command` — central call/lead/discussion/poll hub): `/employee` room `employee_<employeeId>` events `leadDialedCall`/`leadCameCall`/`leadCallEnded`/`leadCallPickUP`/`onboardingDialedCall`/`onboardingCallEnded`/`onboardingCallPickUP`/`onboardingCameCall`; `command` room `employee-device-<id>` event `yourDevicePermissionChanged`; `command` room `employee-device-<deviceId>-phone` events `makeCall`/`pickCall`/`endCall`; dual `/employee`+`/user` discussion/poll events (same set as `discussion.service.ts`); `/user` dynamic room event `logout-user` (admin-forced logout).

## 6. Connection lifecycle (per namespace) — what growth-socket must implement

### 6.1 `/command`
- Read `dauth` from `handshake.headers.dauth`.
- RPC `command.resolvePlatform({ dauth })` → GrowthCommand looks up `Platform` where `auth: dauth` AND has a `PlatformOptions` row `key: 'command'`. No match → disconnect.
- On success: `client.platformId = result.platformId`. Then RPC `command.registerDevice({ deviceId: handshake.query.deviceId, platformId })` → GrowthCommand upserts `EmployeeDevices`, returns `{ deviceId, roomsToJoin: string[], device }`. growth-socket joins every room in `roomsToJoin` (today: `employee-device-<id>`, conditionally `employee-device-<id>-phone` if platform has `isPhone` option, `growth-manager-devices`), then `client.emit('registerDevice', device)`.
- `handleDisconnect`: no-op today (verify with product owner this is intentional before replicating, but preserve as-is by default).

### 6.2 `/employee`
- Read `dauth` from `handshake.headers.dauth` **or** `handshake.auth.dauth`.
- RPC `employee.resolvePlatform({ dauth, origin: handshake.headers.origin })` → match by `origin` OR `auth`, **and** `platform.name === 'Growth Manager'` (hardcoded tenant-name check — preserve). No match → disconnect (no error emitted to client today; consider adding one during migration since it's a UX no-op today, but flag as a deliberate change if you do).
- RPC `employee.registerDevice({ deviceId: handshake.query.deviceId, platformId, version: handshake.query.version })` → returns `roomsToJoin` (`employee-device-<id>`, `growth-manager-devices`) + emits `platformOption` back, and separately triggers a broadcast of `onlineDevice` to `/employee` room `canViewDevice` (this is one of the async pushes from §5, happens automatically once `NotificationService` is wired — no special growth-socket code needed).
- **`login` event** (separate from connection): RPC `employee.login({ email, password })`. GrowthCommand does the existing auth logic (find employee, verify password, resolve permission tree recursively up to 2 levels) and returns:
  ```ts
  { success, data: { employee, permissions }, roomsToJoin: string[] }
  ```
  where `roomsToJoin` = `online_employee`, `employee_<id>`, every resolved permission name (`canViewLeads`, `EmployeeAdd`, `DeviceView`, etc. — this is the **authorization-via-room-membership** mechanism, must be complete/correct), and every `chat_room_<id>` the employee belongs to. growth-socket joins all of them, sets `session.employeeId = employee.id`, then emits `loginsuccess`, `onlineEmployees`, `employeepermissions` to the client per the existing 3-emit pattern. Before joining `online_employee`, GrowthCommand should still do its existing dedupe check (is this employee already connected elsewhere) — that check needs `fetchSockets()` on room `online_employee`, which only growth-socket can do (it owns the sockets) — so this specific check must happen **client-side of the RPC**, i.e. growth-socket calls `server.of('/employee').in('online_employee').fetchSockets()`, checks for an existing `employeeId` match, and only proceeds with the RPC login call if clear (or passes the existing-session info to GrowthCommand as part of the RPC request so GrowthCommand can decide). Recommend the former (check locally, short-circuit before the RPC round-trip).
- `handleDisconnect`: RPC `employee.cleanupConnection({ session })` — GrowthCommand ends open `EmployeeToNumber` assignments, closes open attendance/break records; the resulting broadcasts (`callingNumbersChangedOut`, `employeelogout`, `onlineDevice`) arrive back at growth-socket asynchronously via the `socket.notify` channel (§5), not as a direct RPC response — no special handling needed beyond calling the RPC and letting it fire.
- `logout` event does the same cleanup as disconnect — same RPC.

### 6.3 `/user`
- Read `dauth` from `handshake.auth.dauth` **or** `handshake.headers.dauth`, or platform `origin` match (normalize origin: strip `www.`, force `https://`).
- RPC `user.resolvePlatform({ dauth, origin })`. No match → `client.emit('connectionError', 'Platform Not Found')` then disconnect (this namespace, unlike the other two, emits an explicit reason string — preserve this UX).
- If the resolved platform has `PlatformOptions.key === 'isDevice'`: require `handshake.query.deviceId` and `handshake.query.version` (emit `connectionError` with a specific reason for each missing/stale case — `'Device Id Required'`, `'Version Required'`, `'Version Not Supported'`), then RPC `user.verifyDevice({ deviceId, platformId })`; if not registered, `connectionError: 'Device Not Registered'` + disconnect. On success, join room `user_device__platform_<platformId>_<deviceId>`.
- On full success: `client.platformId = platformId`, emit `connectionSuccess`.
- **`login` event**: RPC `user.login({ token })` — GrowthCommand verifies the JWT (existing `AuthService.wsLogin` logic), returns `{ success, data: { user }, roomsToJoin }`. Preserve whatever room-join list `wsLogin` currently produces (at minimum `user_platform_<userId>_<platformId>`, used as the addressable room for direct notifications like `user_enrolled`, `new_friend_request`, etc.) — **before implementing, re-derive the exact room list from `src/auth/auth.service.ts` `wsLogin`/the continuation code**, since the original research pass didn't capture 100% of it (call out explicitly: verify this against source before shipping).
- **`identify` event**: `client.join(data.identify)` — **handle entirely locally in growth-socket**, no RPC. This lets a client join an arbitrary self-chosen room name, used purely as a target for the WebRTC signaling relay events (`call-start-offer` etc., §4.2) — those four events plus `identify` should be implemented as pure local Socket.IO relays in growth-socket, never touching RabbitMQ.
- `handleDisconnect`: RPC `user.disconnectSocket({ session })` — GrowthCommand handles practice/quiz attempt disconncet bookkeeping and JWT session cleanup (`wsLogout`) if `session.userId` was set.

## 7. Suggested implementation shape for growth-socket

Because most events are pure relays with an identical shape, implement one generic handler per namespace driven by a config array instead of 39+26 hand-written methods:

```ts
const EMPLOYEE_EVENTS = [
  { event: 'login', pattern: 'employee.login', success: ['loginsuccess', 'onlineEmployees', 'employeepermissions'], error: 'loginError', mode: 'rpc' },
  { event: 'checkForBreak', pattern: 'employee.checkForBreak', success: ['break'], mode: 'rpc' },
  { event: 'chat_typing', mode: 'local-relay', handler: (client, data) => server.of('/employee').to(`chat_room_${data.roomId}`).emit('typing', { employeeId: client.employeeId, ...data }) },
  // ...one row per table in §4.1
];

EMPLOYEE_EVENTS.forEach(cfg => {
  gateway.registerHandler(cfg.event, async (client, data) => {
    if (cfg.mode === 'local-relay') return cfg.handler(client, data);
    const req = { session: sessionOf(client), payload: data };
    const res = cfg.mode === 'rpc'
      ? await firstValueFrom(employeeClient.send(cfg.pattern, req).pipe(timeout(10000)))
      : employeeClient.emit(cfg.pattern, req);
    if (cfg.mode !== 'rpc') return;
    if (res.success) (cfg.success || []).forEach((evt, i) => client.emit(evt, i === 0 ? res.data : res.data?.[evt]));
    else if (cfg.error) client.emit(cfg.error, res.message);
  });
});
```
(Illustrative — adapt to however growth-socket structures its gateway classes; the point is the 65+ event handlers reduce to one generic relay plus a per-event config table, which is exactly the tables in §4.1–§4.3.)

## 8. Migration / rollout plan

1. Build growth-socket against this spec, pointed at a **staging** RabbitMQ, without touching GrowthCommand yet.
2. In GrowthCommand: add the RPC-listener side (`@MessagePattern` controllers wrapping existing service methods) behind the new queue(s) from §4, and the `NotificationService` RMQ-publish rewrite from §5 — but **keep the existing in-process gateways running too**, gated behind an env flag (e.g. `SOCKET_MODE=embedded|external`), so you can flip back instantly if something's wrong.
3. Cut over one namespace at a time, smallest blast radius first: `/command` (4 events, all local relays) → `/employee` → `/user`.
4. Once all three are stable on growth-socket, delete the in-process gateways, `MainGatewayGateway`/`main-gateway` module, and the embedded `RedisIoAdapter` wiring from GrowthCommand's `main.ts`.
5. Watch for the two flagged pre-existing quirks during cutover (don't silently fix them mid-migration — call out separately): the hardcoded `platform id 8` in `platform.service.ts`'s `device-unregistered` emit, and the mislabeled error events (`getPaymentsError` used for device-allow errors, `loginError` reused for course-add errors, `leadSave-error` reused for form-data errors).

## 9. Open decisions for the new project's owner

- Option A vs Option B for connection-time DB access (§3) — recommend A.
- Per-namespace queues vs one shared `socket_rpc_queue` (§4) — recommend per-namespace, mirrors existing module boundaries and lets each namespace scale/deploy its consumer independently within GrowthCommand.
- `durable: false` queues (matches existing geo/main_queue convention) vs `durable: true` for the new queues, given call-signaling and lead-routing events are more failure-sensitive than geo lookups.
- Whether to add an explicit `connectionError` emit on `/employee` and `/command` handshake rejection (today they silently disconnect) for UX parity with `/user` — not required for a faithful migration, but worth deciding deliberately rather than by accident.
