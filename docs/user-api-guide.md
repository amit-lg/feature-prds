# GrowthCommand — User-Facing API Developer Guide

## Table of Contents
1. [Tech Stack](#1-tech-stack)
2. [Project Structure](#2-project-structure)
3. [How Every Request Works](#3-how-every-request-works)
4. [Creating a New Module](#4-creating-a-new-module)
5. [Writing the Controller](#5-writing-the-controller)
6. [Writing DTOs](#6-writing-dtos)
7. [Writing the Service](#7-writing-the-service)
8. [Authentication Modes](#8-authentication-modes)
9. [Accessing Request Context](#9-accessing-request-context)
10. [Database Access](#10-database-access)
11. [Quick Reference](#11-quick-reference)

---

## 1. Tech Stack

| Layer | Technology |
|---|---|
| Framework | NestJS 11 (Express adapter) |
| Language | TypeScript (CommonJS, `strictNullChecks` off) |
| Database | PostgreSQL via Prisma 7 (pg adapter) |
| Cache | Redis (Keyv) |
| Auth | JWT (`@nestjs/jwt`) |
| Validation | `class-validator` + `class-transformer` |
| File uploads | `@nestjs/platform-express` (multer) |
| API docs | Swagger (`@nestjs/swagger`) available at `/apiname` in dev |

Global route prefix is `api`. A controller at `@Controller('user')` is reachable at `/api/user`.

---

## 2. Project Structure

```
src/
  <feature>/
    <feature>.module.ts       # NestJS module + middleware wiring
    <feature>.controller.ts   # Route handlers
    <feature>.service.ts      # Business logic
    dto/                      # Request/response shapes
    entities/                 # Type definitions
  common/
    middleware/
      platformcheck.middleware.ts   # Resolves platformId from every request
    interface/
      custom-request.interface.ts   # Extended Request type
  auth/
    guards/
      auth.guard.ts           # Requires a logged-in user token
      checkauth.guard.ts      # Optionally identifies user; does not block
  database/
    database.service.ts       # Single Prisma client — inject this everywhere
  generated/
    prisma/                   # Generated Prisma client — import from here
```

Every new feature is a self-contained folder following this layout.

---

## 3. How Every Request Works

Two things happen before any route handler runs:

```
Request
  │
  ├─ PlatformCheckMiddleware   (reads Origin or dauth header → sets req.platformId)
  │                             Rejects with 406 if neither header is present
  │                             or platform is not found in DB.
  │
  ├─ AuthGuard / CheckAuthGuard (optional, added per-route with @UseGuards)
  │                             AuthGuard      → requires valid JWT → sets req.userId
  │                             CheckAuthGuard → JWT optional → sets req.userId = 0 if absent
  │
  └─ Route Handler
```

**Headers required by every request:**

| Header | Value | Required |
|---|---|---|
| `Origin` | The platform's configured origin URL (e.g. `https://example.com`) | One of these two |
| `dauth` | The platform's secret auth key | One of these two |
| `Authorization` | `Bearer <jwt>` | Only for guarded routes |

---

## 4. Creating a New Module

### 4.1 Generate the scaffold

```bash
nest g module <feature>
nest g controller <feature>
nest g service <feature>
```

### 4.2 Module file

```typescript
// src/<feature>/<feature>.module.ts
import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { FeatureController } from './<feature>.controller';
import { FeatureService } from './<feature>.service';
import { DatabaseModule } from 'src/database/database.module';
import { PlatformCheckMiddleware } from 'src/common/middleware/platformcheck.middleware';

@Module({
  imports: [DatabaseModule],
  controllers: [FeatureController],
  providers: [FeatureService, PlatformCheckMiddleware],
})
export class FeatureModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(PlatformCheckMiddleware).forRoutes(FeatureController);
  }
}
```

**Rules:**
- Always `implements NestModule` and wire `PlatformCheckMiddleware` in `configure()`. Without this, `req.platformId` is never set and all downstream DB lookups will break.
- Always include `DatabaseModule` in `imports`.
- Add any cross-module services (e.g. `EmailsModule`, `LeadModule`) to `imports` as needed.
- Register the module in `src/app.module.ts` `imports` array.

---

## 5. Writing the Controller

```typescript
// src/<feature>/<feature>.controller.ts
import {
  Controller, Get, Post, Patch, Delete,
  Body, Query, Param, Request,
  UseGuards, ValidationPipe, HttpCode, HttpStatus,
} from '@nestjs/common';
import { ApiBearerAuth } from '@nestjs/swagger';
import { FeatureService } from './<feature>.service';
import { AuthGuard } from 'src/auth/guards/auth.guard';
import { CheckAuthGuard } from 'src/auth/guards/checkauth.guard';
import { CustomRequest } from 'src/common/interface/custom-request.interface';
import { CreateFeatureDto } from './dto/create-feature.dto';

@Controller('<feature>')
@ApiBearerAuth()
export class FeatureController {
  constructor(private readonly featureService: FeatureService) {}

  // Public endpoint — no auth required, platformId still set by middleware
  @Get()
  getAll(@Request() req: CustomRequest) {
    return this.featureService.getAll(req.platformId);
  }

  // Optional auth — works for both guests (userId = 0) and logged-in users
  @UseGuards(CheckAuthGuard)
  @Get('detail')
  getDetail(@Request() req: CustomRequest) {
    return this.featureService.getDetail(req.platformId, req.userId);
  }

  // Requires login
  @UseGuards(AuthGuard)
  @Post()
  create(
    @Request() req: CustomRequest,
    @Body(new ValidationPipe()) createFeatureDto: CreateFeatureDto,
  ) {
    return this.featureService.create(req.userId, req.platformId, createFeatureDto);
  }

  // Requires login, query params with type coercion
  @UseGuards(AuthGuard)
  @Get('list')
  list(
    @Request() req: CustomRequest,
    @Query(new ValidationPipe({ transform: true })) queryDto: QueryFeatureDto,
  ) {
    return this.featureService.list(req.platformId, queryDto);
  }

  // Route param
  @UseGuards(AuthGuard)
  @Get(':id')
  findOne(@Param('id') id: string, @Request() req: CustomRequest) {
    return this.featureService.findOne(+id, req.userId);
  }

  // Override default 201 to 200
  @UseGuards(AuthGuard)
  @HttpCode(HttpStatus.OK)
  @Post('action')
  action(@Request() req: CustomRequest) {
    return this.featureService.action(req.userId);
  }
}
```

**Rules:**
- Always add `@UseGuards(AuthGuard)` on any route that needs `req.userId`.
- Use `@UseGuards(CheckAuthGuard)` when the route works for both guests and logged-in users.
- Always pass `new ValidationPipe()` when using a DTO on `@Body` or `@Query`.
- Use `new ValidationPipe({ transform: true })` on `@Query` so string query params are coerced to numbers automatically.
- Pass the entire `req.platformId` and `req.userId` to the service — never access `req` inside the service.

---

## 6. Writing DTOs

DTOs live in `<feature>/dto/`. Use `class-validator` decorators for all validation.

### 6.1 Body DTO

```typescript
// src/<feature>/dto/create-feature.dto.ts
import { ApiProperty } from '@nestjs/swagger';
import {
  IsString, IsNotEmpty, IsOptional, IsNumber,
  IsArray, IsBoolean, IsEmail, MinLength, Matches,
  ValidateIf, IsEnum,
} from 'class-validator';

export class CreateFeatureDto {
  @ApiProperty({ required: true })
  @IsNotEmpty()
  @IsString()
  name: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsNumber()
  amount?: number;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsArray()
  utms?: object[];
}
```

### 6.2 Query DTO (numbers from query strings)

```typescript
import { Transform } from 'class-transformer';
import { IsNumber, IsOptional, IsString } from 'class-validator';

export class QueryFeatureDto {
  @Transform(({ value }) => parseInt(value, 10))
  @IsOptional()
  @IsNumber()
  page?: number;

  @Transform(({ value }) => parseInt(value, 10))
  @IsOptional()
  @IsNumber()
  limit?: number;

  @IsOptional()
  @IsString()
  search?: string;
}
```

**Rules:**
- Always use `@Transform(({ value }) => parseInt(value, 10))` before `@IsNumber()` on query params — query strings are always strings; without this, validation will fail.
- Add `@ApiProperty()` to every field for Swagger docs.
- Use `@IsOptional()` for optional fields; required fields need `@IsNotEmpty()`.
- `utms: object[]` with `@IsOptional() @IsArray()` is the standard UTM tracking field — add it to any body DTO that represents a user action.

---

## 7. Writing the Service

```typescript
// src/<feature>/<feature>.service.ts
import { Injectable, NotFoundException } from '@nestjs/common';
import { DatabaseService } from 'src/database/database.service';
import { CreateFeatureDto } from './dto/create-feature.dto';

@Injectable()
export class FeatureService {
  constructor(private readonly databaseService: DatabaseService) {}

  async getAll(platformId: number) {
    return this.databaseService.someModel.findMany({
      where: { platformId },
    });
  }

  async create(userId: number, platformId: number, dto: CreateFeatureDto) {
    return this.databaseService.someModel.create({
      data: {
        ...dto,
        userId,
        platformId,
      },
    });
  }

  async findOne(id: number, userId: number) {
    const record = await this.databaseService.someModel.findFirst({
      where: { id, userId },
    });
    if (!record) {
      throw new NotFoundException('Record not found');
    }
    return record;
  }
}
```

**Rules:**
- Always inject `DatabaseService`, never import `PrismaClient` directly.
- Import `DatabaseService` from `src/database/database.service`, not from `@prisma/client`.
- If you need Prisma model types, import from `src/generated/prisma/client`.
- Always scope DB queries by `platformId` (multi-tenant). Forgetting this leaks data across platforms.
- Always scope writes by `userId` when the data belongs to a user.

---

## 8. Authentication Modes

### `AuthGuard` — user must be logged in

Use for any route that creates, modifies, or reads user-owned data.

After this guard runs, `req.userId` is the authenticated user's ID and `req.platformId` is already set by the middleware.

```typescript
@UseGuards(AuthGuard)
@Get('profile')
getProfile(@Request() req: CustomRequest) {
  // req.userId  → guaranteed to be a valid user ID
  // req.platformId → guaranteed to be the platform
}
```

### `CheckAuthGuard` — auth is optional

Use for routes that return public data but want to personalise the response if the user is logged in (e.g. show "is enrolled" flag).

```typescript
@UseGuards(CheckAuthGuard)
@Get('courses')
getCourses(@Request() req: CustomRequest) {
  // req.userId → logged-in user's ID, or 0 if not logged in
  // req.platformId → always set
}
```

### No guard — fully public

No `@UseGuards` decorator. `req.platformId` is still set. Do not access `req.userId` — it is undefined.

```typescript
@Get('faqs')
getFaqs(@Request() req: CustomRequest) {
  // req.platformId → set
  // req.userId     → DO NOT USE — undefined
}
```

---

## 9. Accessing Request Context

The `CustomRequest` interface extends Express `Request` with these properties:

```typescript
import { CustomRequest } from 'src/common/interface/custom-request.interface';

// req.platformId  number   — set by PlatformCheckMiddleware on every request
// req.userId      number   — set by AuthGuard / CheckAuthGuard (0 if not logged in with CheckAuthGuard)
// req.token       string   — raw JWT string (set by AuthGuard)
```

Always type route handler parameters as `@Request() req: CustomRequest`.

---

## 10. Database Access

The Prisma client is accessed through `DatabaseService`. The model names match the Prisma schema exactly.

```typescript
// Find one
const record = await this.databaseService.someModel.findFirst({
  where: { id, platformId },
  include: { RelatedModel: true },
});

// Find many
const records = await this.databaseService.someModel.findMany({
  where: { platformId, status: 'active' },
  orderBy: { createdAt: 'desc' },
  skip: (page - 1) * limit,
  take: limit,
});

// Create
const created = await this.databaseService.someModel.create({
  data: { ...dto, userId, platformId },
});

// Update
const updated = await this.databaseService.someModel.update({
  where: { id },
  data: { field: value },
});

// Update many
await this.databaseService.someModel.updateMany({
  where: { userId, status: 'pending' },
  data: { status: 'done' },
});

// Upsert
await this.databaseService.someModel.upsert({
  where: { uniqueField: value },
  update: { field: newValue },
  create: { ...allFields },
});

// Count
const total = await this.databaseService.someModel.count({
  where: { platformId },
});
```

**Schema changes:** After editing `prisma/schema.prisma`, run:
```bash
npx prisma migrate dev --name <describe-change>
npx prisma generate
```

The generated client in `src/generated/prisma/` must be committed.

---

## 11. Quick Reference

### Checklist for a new endpoint

- [ ] Module has `PlatformCheckMiddleware` wired in `configure()`
- [ ] Module has `DatabaseModule` in `imports`
- [ ] Module is registered in `app.module.ts`
- [ ] Controller uses `@UseGuards(AuthGuard)` on protected routes
- [ ] Body DTOs validated with `@Body(new ValidationPipe())`
- [ ] Query DTOs validated with `@Query(new ValidationPipe({ transform: true }))`
- [ ] Query DTOs use `@Transform(({ value }) => parseInt(value, 10))` on numeric fields
- [ ] Service queries are scoped by `platformId`
- [ ] Service imports `DatabaseService` from `src/database/database.service`

### Common exceptions

```typescript
import {
  NotFoundException,        // 404 — record not found
  BadRequestException,      // 400 — invalid input
  UnauthorizedException,    // 401 — auth failed
  ForbiddenException,       // 403 — not allowed
  ConflictException,        // 409 — duplicate
  NotAcceptableException,   // 406 — platform/cors error
} from '@nestjs/common';

throw new NotFoundException('Course not found');
```

### JWT token claims

Tokens issued by this system encode:

```typescript
{
  userId: number,
  platformId: number,
  path: 'auth',       // user tokens always have path = 'auth'
}
```

`AuthGuard` verifies `path === 'auth'` and that `payload.platformId === req.platformId`. Tokens from a different platform are rejected even if the signature is valid.

### File uploads

```typescript
import { UseInterceptors, UploadedFiles } from '@nestjs/common';
import { FileFieldsInterceptor } from '@nestjs/platform-express';

@UseGuards(AuthGuard)
@Post('upload')
@UseInterceptors(FileFieldsInterceptor([{ name: 'file', maxCount: 1 }]))
upload(
  @UploadedFiles() files: { file?: Express.Multer.File[] },
  @Request() req: CustomRequest,
) {
  const file = files?.file?.[0];
  // pass to VultrService or similar for S3-compatible storage
}
```

For multipart bodies that also have text fields, use `@UseInterceptors(AnyFilesInterceptor())` with `@Body(new ValidationPipe())`.
