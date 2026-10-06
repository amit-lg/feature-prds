-- Data backfill for the "reverse UserLeadActivity FK ownership" migration.
--
-- MUST run BEFORE the corresponding schema migration (20260713062138_leadaddecwithmigrationforactivity)
-- drops UserLeadActivity.cartId/paymentId/contactFormId/interactionId -- this script still
-- relies on all of those columns existing.
--
-- NOTE: the UserToPlatform.leadId backfill is handled separately in
-- 02_usertoplatform_leadid_backfill.sql, because that column doesn't exist yet at this point
-- in the migration sequence -- it's only added by 20260713062138, so it can't be backfilled
-- until AFTER that migration is deployed. Running it here as one transaction with Steps 1-2
-- would error on the missing column and roll back everything, including the successful work
-- below.
--
-- Safe to re-run (idempotent): every UPDATE is scoped to rows that still need it.

BEGIN;

-- Step 1: backfill each child table's activityId from UserLeadActivity's legacy scalar FK,
-- for any row where activityId is still null (covers rows created before the activityId
-- back-link pattern existed, and command.service.ts's dialNumber/cameCall interactions,
-- which never wrote activityId). Picks the most recently created matching activity.

WITH latest AS (
  SELECT DISTINCT ON ("cartId") "cartId", "id" AS "activityId"
  FROM "UserLeadActivity"
  WHERE "cartId" IS NOT NULL
  ORDER BY "cartId", "createdAt" DESC, "id" DESC
)
UPDATE "UserCart" c
SET "activityId" = latest."activityId"
FROM latest
WHERE c."id" = latest."cartId" AND c."activityId" IS NULL;

WITH latest AS (
  SELECT DISTINCT ON ("paymentId") "paymentId", "id" AS "activityId"
  FROM "UserLeadActivity"
  WHERE "paymentId" IS NOT NULL
  ORDER BY "paymentId", "createdAt" DESC, "id" DESC
)
UPDATE "UserPayments" p
SET "activityId" = latest."activityId"
FROM latest
WHERE p."id" = latest."paymentId" AND p."activityId" IS NULL;

WITH latest AS (
  SELECT DISTINCT ON ("contactFormId") "contactFormId", "id" AS "activityId"
  FROM "UserLeadActivity"
  WHERE "contactFormId" IS NOT NULL
  ORDER BY "contactFormId", "createdAt" DESC, "id" DESC
)
UPDATE "UserContactForm" cf
SET "activityId" = latest."activityId"
FROM latest
WHERE cf."id" = latest."contactFormId" AND cf."activityId" IS NULL;

WITH latest AS (
  SELECT DISTINCT ON ("interactionId") "interactionId", "id" AS "activityId"
  FROM "UserLeadActivity"
  WHERE "interactionId" IS NOT NULL
  ORDER BY "interactionId", "createdAt" DESC, "id" DESC
)
UPDATE "UserLeadInteraction" i
SET "activityId" = latest."activityId"
FROM latest
WHERE i."id" = latest."interactionId" AND i."activityId" IS NULL;

-- Step 2: resolve any activityId shared by more than one row in the same table (from
-- pre-existing data or step 1). Keeps the most recently created row's link, nulls the rest.
-- Confirm zero duplicates remain (per table, per activityId) before applying the schema
-- migration that adds the UNIQUE constraints.

WITH ranked AS (
  SELECT "id", ROW_NUMBER() OVER (PARTITION BY "activityId" ORDER BY "createdAt" DESC, "id" DESC) AS rn
  FROM "UserCart"
  WHERE "activityId" IS NOT NULL
)
UPDATE "UserCart" c SET "activityId" = NULL FROM ranked r WHERE c."id" = r."id" AND r.rn > 1;

WITH ranked AS (
  SELECT "id", ROW_NUMBER() OVER (PARTITION BY "activityId" ORDER BY "createdAt" DESC, "id" DESC) AS rn
  FROM "UserPayments"
  WHERE "activityId" IS NOT NULL
)
UPDATE "UserPayments" p SET "activityId" = NULL FROM ranked r WHERE p."id" = r."id" AND r.rn > 1;

WITH ranked AS (
  SELECT "id", ROW_NUMBER() OVER (PARTITION BY "activityId" ORDER BY "createdAt" DESC, "id" DESC) AS rn
  FROM "UserContactForm"
  WHERE "activityId" IS NOT NULL
)
UPDATE "UserContactForm" cf SET "activityId" = NULL FROM ranked r WHERE cf."id" = r."id" AND r.rn > 1;

WITH ranked AS (
  SELECT "id", ROW_NUMBER() OVER (PARTITION BY "activityId" ORDER BY "createdAt" DESC, "id" DESC) AS rn
  FROM "UserLeadInteraction"
  WHERE "activityId" IS NOT NULL
)
UPDATE "UserLeadInteraction" i SET "activityId" = NULL FROM ranked r WHERE i."id" = r."id" AND r.rn > 1;

COMMIT;

-- After this script: confirm no activityId is shared by more than one row in any of the
-- four child tables before applying the schema migration. Then, once
-- 20260713062138_leadaddecwithmigrationforactivity has been deployed (which adds
-- UserToPlatform.leadId), run 02_usertoplatform_leadid_backfill.sql before
-- 20260716041653_usertoplatforminactivity drops that column again.
