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

-- Re-runnable: the guard at the end would refuse the trigger drops below. Recreated there.
DROP EVENT TRIGGER IF EXISTS evidence_protect_audit_log_triggers;

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
    'audit guard: % row % (age %s) is inside the 180-day retention floor and cannot be deleted by %',
    TG_TABLE_NAME, OLD.id, extract(epoch from now())::bigint - OLD.created_at, session_user
    USING HINT = 'Drop trigger trg_protect_audit_logs on this table as a superuser if this is a deliberate purge.';
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

-- Without this an UPDATE of type turns an audit row into a consumption row the delete floor
-- no longer covers.
DROP TRIGGER IF EXISTS trg_protect_audit_logs_update ON logs;
CREATE TRIGGER trg_protect_audit_logs_update
  BEFORE UPDATE ON logs
  FOR EACH ROW
  WHEN (OLD.type = 3)
  EXECUTE FUNCTION protect_audit_log_update();

-- v1 also installed a BEFORE TRUNCATE trigger. It is not recreated: the REVOKE
-- above removes the privilege from the app role, and a trigger would only have
-- re-introduced the same bypass question for postgres.
DROP TRIGGER IF EXISTS trg_protect_audit_logs_truncate ON logs;
DROP FUNCTION IF EXISTS protect_audit_log_truncate();

-- audit_logs (logins, admin actions, refused checks, key reveals) is append-only: the gateway
-- only inserts, so updates are refused outright and deletes share the 180-day floor.
REVOKE TRUNCATE ON audit_logs FROM newapi;

CREATE OR REPLACE FUNCTION protect_audit_log_update() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit guard: % row % is append-only and cannot be updated by %', TG_TABLE_NAME, OLD.id, session_user
    USING HINT = 'Drop trigger trg_protect_audit_logs_update on this table as a superuser if this is deliberate.';
END;
$$ LANGUAGE plpgsql;

REVOKE ALL ON FUNCTION protect_audit_log_update() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_protect_audit_logs ON audit_logs;
CREATE TRIGGER trg_protect_audit_logs
  BEFORE DELETE ON audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION protect_audit_log_rows();

DROP TRIGGER IF EXISTS trg_protect_audit_logs_update ON audit_logs;
CREATE TRIGGER trg_protect_audit_logs_update
  BEFORE UPDATE ON audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION protect_audit_log_update();

-- The app role owns both tables: it could drop, disable or redefine the triggers above, or
-- grant itself TRUNCATE back. After every DDL statement (GRANT included) this checks the four
-- triggers are enabled and defined exactly as above and that newapi holds no TRUNCATE, and
-- rolls the statement back otherwise.
CREATE OR REPLACE FUNCTION public.protect_audit_log_triggers() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF session_user = 'postgres' THEN RETURN; END IF;
  IF to_regclass('public.audit_logs') IS NULL OR to_regclass('public.logs') IS NULL THEN
    RAISE EXCEPTION 'audit guard: audit tables require database administrator maintenance';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
      WHERE tgrelid IN ('public.audit_logs'::regclass, 'public.logs'::regclass)
      AND tgenabled IN ('O','A') AND NOT tgisinternal
      AND pg_get_triggerdef(oid) IN (
        'CREATE TRIGGER trg_protect_audit_logs BEFORE DELETE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION protect_audit_log_rows()',
        'CREATE TRIGGER trg_protect_audit_logs_update BEFORE UPDATE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION protect_audit_log_update()',
        'CREATE TRIGGER trg_protect_audit_logs BEFORE DELETE ON public.logs FOR EACH ROW WHEN ((old.type = 3)) EXECUTE FUNCTION protect_audit_log_rows()',
        'CREATE TRIGGER trg_protect_audit_logs_update BEFORE UPDATE ON public.logs FOR EACH ROW WHEN ((old.type = 3)) EXECUTE FUNCTION protect_audit_log_update()')) <> 4 THEN
    RAISE EXCEPTION 'audit guard: audit log trigger definitions require database administrator maintenance';
  END IF;
  IF has_table_privilege('newapi', 'public.audit_logs', 'TRUNCATE')
  OR has_table_privilege('newapi', 'public.logs', 'TRUNCATE') THEN
    RAISE EXCEPTION 'audit guard: TRUNCATE on the audit tables stays revoked from newapi';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_audit_log_triggers() FROM PUBLIC, newapi;
CREATE EVENT TRIGGER evidence_protect_audit_log_triggers ON ddl_command_end
  EXECUTE FUNCTION public.protect_audit_log_triggers();

-- A table rewrite (ALTER COLUMN ... TYPE ... USING) runs no row trigger, so it could age
-- every audit row past the delete floor or rewrite users.access_token unrecorded. AutoMigrate
-- never rewrites these tables; a real upstream type change is applied by an administrator.
CREATE OR REPLACE FUNCTION public.protect_audit_table_rewrite() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF session_user = 'postgres' THEN RETURN; END IF;
  IF pg_event_trigger_table_rewrite_oid() IN ('public.audit_logs'::regclass, 'public.logs'::regclass, 'public.users'::regclass) THEN
    RAISE EXCEPTION 'audit guard: rewriting % requires database administrator maintenance', pg_event_trigger_table_rewrite_oid()::regclass;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_audit_table_rewrite() FROM PUBLIC, newapi;
DROP EVENT TRIGGER IF EXISTS evidence_protect_audit_table_rewrite;
CREATE EVENT TRIGGER evidence_protect_audit_table_rewrite ON table_rewrite
  EXECUTE FUNCTION public.protect_audit_table_rewrite();

COMMIT;
