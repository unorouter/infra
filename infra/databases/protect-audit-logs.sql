-- Stops the application role from erasing the security audit trail in `logs`.
--
-- Every security event the gateway records is a type=3 row here:
-- refused auth and permission checks, key reveals, bulk reads, token lifecycle,
-- email and OAuth binding changes. quota_audit was made append-only for exactly
-- this reason; `logs` holds far more of the evidence and had nothing.
--
-- WHAT THE FIRST ATTEMPT GOT WRONG (2026-08-27, and it cost 9.2M rows):
--
-- v1 used two triggers that both began `IF session_user = 'postgres' THEN RETURN`.
-- The intent was an operator escape hatch. The effect was that the protection did
-- not apply to the one account most able to destroy the table, and a TRUNCATE run
-- from a postgres psql session emptied it. `SET ROLE newapi` does not help either:
-- SET ROLE leaves session_user as postgres, so "testing as the app role" tested
-- nothing and reported success while the guard was inert.
--
-- The lesson is not "write a better exemption". It is that a guard with a bypass
-- protects only against the actors who were never the threat. This version has no
-- bypass at all: postgres, newapi and every other role are refused equally, and
-- lifting the protection is a deliberate DROP TRIGGER that an operator must type
-- knowingly rather than a condition they satisfy by accident.
--
-- WHY NOT OWNERSHIP:
--
-- A table's owner always holds DELETE and TRUNCATE regardless of grants, so making
-- this stick by ownership would mean reparenting `logs` to postgres. The
-- application runs AutoMigrate(&Log{}) at every boot (model/main.go:513) and needs
-- ownership to ALTER, and this is a fork that merges upstream, where the Log struct
-- has changed repeatedly. Reparenting would eventually fail a boot during an
-- unrelated merge. Triggers give most of the protection with none of that risk.
--
-- WHAT RETENTION ACTUALLY NEEDS:
--
-- Measured before writing this: `logs` holds rows back to 2026-01-15, 7+ months,
-- so cleanup has never run. The only deletion path in the codebase is
-- DeleteOldLogBatch (model/log.go:866), reached solely through
-- POST /api/system-task/log-cleanup, which is already SessionOnly()-gated. Nothing
-- issues TRUNCATE against this table. So TRUNCATE is revoked outright, and DELETE
-- keeps working for everything except recent audit rows.

BEGIN;

-- Nothing in the application truncates this table, and TRUNCATE fires no row
-- trigger, so leaving the privilege in place would leave a one-word bypass of
-- everything below. Revoked rather than trigger-guarded: a privilege the app does
-- not hold cannot be misused by a compromised app, whereas a trigger can only
-- refuse after the statement is attempted.
REVOKE TRUNCATE ON logs FROM newapi;

-- 180 days. Long enough that a slow-burn compromise stays reconstructable, short
-- enough that audit rows do not outlive their usefulness and the table can still
-- be pruned.
CREATE OR REPLACE FUNCTION protect_audit_log_rows() RETURNS trigger AS $$
BEGIN
  -- No role exemption, deliberately. See the header: the postgres bypass in v1 is
  -- precisely what let the table be emptied.
  IF OLD.created_at < extract(epoch from now())::bigint - 15552000 THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION
    'audit row % (type=3, age %s) is inside the 180-day retention floor and cannot be deleted by %',
    OLD.id, extract(epoch from now())::bigint - OLD.created_at, session_user
    USING HINT = 'Drop trigger trg_protect_audit_logs as a superuser if this is a deliberate purge.';
END;
$$ LANGUAGE plpgsql;

REVOKE ALL ON FUNCTION protect_audit_log_rows() FROM PUBLIC;

-- WHEN keeps the function off the hot path entirely: a retention batch over type=2
-- consumption rows (the overwhelming bulk of 9.3M) never enters it, so cleanup runs
-- at full speed and only audit rows pay for the check.
DROP TRIGGER IF EXISTS trg_protect_audit_logs ON logs;
CREATE TRIGGER trg_protect_audit_logs
  BEFORE DELETE ON logs
  FOR EACH ROW
  WHEN (OLD.type = 3)
  EXECUTE FUNCTION protect_audit_log_rows();

-- v1 also installed a BEFORE TRUNCATE trigger. It is not recreated: the REVOKE
-- above removes the privilege from the app role, and a trigger would only have
-- re-introduced the same bypass question for postgres.
DROP TRIGGER IF EXISTS trg_protect_audit_logs_truncate ON logs;
DROP FUNCTION IF EXISTS protect_audit_log_truncate();

COMMIT;
