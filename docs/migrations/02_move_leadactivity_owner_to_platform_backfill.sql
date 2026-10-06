-- Data backfill for the "move UserLeadActivity ownership from User onto UserToPlatform"
-- migration.
--
-- MUST run BEFORE two separately-applied schema changes: (1) dropping
-- UserLeadActivity.userId / UserToPlatform.leadId (this script still reads userId), and
-- (2) dropping the standalone UNIQUE constraint on UserToPlatform.userId. Step 1 below
-- assumes each user still has at most one UserToPlatform row (true today, since that
-- constraint hasn't been dropped yet) -- if run after that constraint is dropped, a user
-- with multiple platform memberships would have all of them incorrectly pointed at the same
-- single "latest" activity, since the legacy UserLeadActivity.userId link never recorded
-- which platform the activity happened on.
--
-- Safe to re-run (idempotent): every UPDATE is scoped to rows that still need it.

BEGIN;

-- Step 1: backfill UserToPlatform.activityId from UserLeadActivity's legacy scalar userId,
-- for any UserToPlatform row where activityId is still null. UserToPlatform.userId is unique,
-- so each user has at most one membership row; picks that user's most recently created
-- activity as the one the membership row now points at.

WITH latest AS (
  SELECT DISTINCT ON ("userId") "userId", "id" AS "activityId"
  FROM "UserLeadActivity"
  WHERE "userId" IS NOT NULL
  ORDER BY "userId", "createdAt" DESC, "id" DESC
)
UPDATE "UserToPlatform" p
SET "activityId" = latest."activityId"
FROM latest
WHERE p."userId" = latest."userId" AND p."activityId" IS NULL;

-- Step 2: resolve any activityId shared by more than one UserToPlatform row (from
-- pre-existing data, since activityId has never had a UNIQUE constraint until now, or from
-- step 1). Keeps the most recently created membership row's link, nulls the rest.

WITH ranked AS (
  SELECT "userId", "platformId",
         ROW_NUMBER() OVER (PARTITION BY "activityId" ORDER BY "createdAt" DESC) AS rn
  FROM "UserToPlatform"
  WHERE "activityId" IS NOT NULL
)
UPDATE "UserToPlatform" p
SET "activityId" = NULL
FROM ranked r
WHERE p."userId" = r."userId" AND p."platformId" = r."platformId" AND r.rn > 1;

-- Step 3: null out any activityId that points at a UserLeadActivity row that no longer
-- exists, so the FK constraint added by the schema migration can be added.

UPDATE "UserToPlatform" p
SET "activityId" = NULL
WHERE p."activityId" IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM "UserLeadActivity" a WHERE a."id" = p."activityId");

COMMIT;

-- After this script: confirm no UserToPlatform row has a duplicate or dangling activityId
-- before applying the schema migration that adds the UNIQUE constraint and FK.
