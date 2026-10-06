-- Data backfill for UserToPlatform.leadId, split out from
-- 01_reverse_lead_activity_fk_backfill.sql because the source column dependency runs the
-- opposite direction from that script's Steps 1-2.
--
-- MUST run AFTER schema migration 20260713062138_leadaddecwithmigrationforactivity is deployed
-- (that migration adds UserToPlatform.leadId -- this script errors if it doesn't exist yet).
--
-- MUST run BEFORE schema migration 20260716041653_usertoplatforminactivity is deployed
-- (that migration drops UserToPlatform.leadId again, now that lookups go through
-- UserToPlatform.activityId directly).
--
-- Safe to re-run (idempotent): the UPDATE is scoped to rows that still need it.

BEGIN;

-- Backfill UserToPlatform.leadId from the lead already linked to the activity
-- UserToPlatform.activityId points at (this column is populated by the existing
-- checkNewSignup code path in lead.service.ts).

UPDATE "UserToPlatform" p
SET "leadId" = a."leadId"
FROM "UserLeadActivity" a
WHERE p."activityId" = a."id" AND p."leadId" IS NULL;

COMMIT;
