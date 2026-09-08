-- PostgreSQL infrastructure audit, deliberately outside application migrations.
-- Install as the database owner. Never record a PAT, its hash, or SQL parameters.
BEGIN;
CREATE TABLE IF NOT EXISTS public.pat_change_audit (
  id bigserial PRIMARY KEY,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  user_id bigint NOT NULL,
  change_kind text NOT NULL CHECK (change_kind IN ('created', 'replaced', 'cleared')),
  db_user text NOT NULL,
  requested_role text,
  app_name text,
  client_addr inet,
  client_port integer,
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS pat_change_audit_changed_at ON public.pat_change_audit(changed_at);
-- Original rows are the durable outbox. An acknowledgement is written only
-- after the archive confirms the exact record; no high-water mark can skip a
-- transaction that commits out of sequence.
CREATE TABLE IF NOT EXISTS public.pat_change_archive_ack (
  event_id bigint PRIMARY KEY REFERENCES public.pat_change_audit(id),
  archived_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'evidence_archiver') THEN
    CREATE ROLE evidence_archiver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
ALTER ROLE evidence_archiver SET statement_timeout = '5s';
GRANT USAGE ON SCHEMA public TO evidence_archiver;
GRANT SELECT ON public.pat_change_audit TO evidence_archiver;
GRANT SELECT, INSERT ON public.pat_change_archive_ack TO evidence_archiver;
REVOKE ALL ON public.pat_change_archive_ack FROM PUBLIC, newapi;
GRANT SELECT ON public.pat_change_audit, public.pat_change_archive_ack TO cnpg_metrics_exporter;
CREATE OR REPLACE FUNCTION public.capture_pat_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE change text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.access_token IS NULL OR NEW.access_token = '' THEN RETURN NEW; END IF;
    change := 'created';
  ELSE
    IF NEW.access_token IS NOT DISTINCT FROM OLD.access_token THEN RETURN NEW; END IF;
    IF NEW.access_token IS NULL OR NEW.access_token = '' THEN
      change := 'cleared';
    ELSIF OLD.access_token IS NULL OR OLD.access_token = '' THEN
      change := 'created';
    ELSE
      change := 'replaced';
    END IF;
  END IF;
  INSERT INTO public.pat_change_audit
    (user_id, change_kind, db_user, requested_role, app_name, client_addr,
     client_port, backend_pid, transaction_id)
  VALUES (NEW.id, change, session_user, current_setting('role', true),
    current_setting('application_name', true), inet_client_addr(),
    inet_client_port(), pg_backend_pid(), txid_current());
  RETURN NEW;
END;
$$;
REVOKE ALL ON public.pat_change_audit FROM PUBLIC, newapi;
REVOKE ALL ON SEQUENCE public.pat_change_audit_id_seq FROM PUBLIC, newapi;
REVOKE ALL ON FUNCTION public.capture_pat_change() FROM PUBLIC, newapi;
DROP TRIGGER IF EXISTS evidence_pat_update ON public.users;
CREATE TRIGGER evidence_pat_update AFTER UPDATE OF access_token ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.capture_pat_change();
DROP TRIGGER IF EXISTS evidence_pat_insert ON public.users;
CREATE TRIGGER evidence_pat_insert AFTER INSERT ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.capture_pat_change();
-- Add object audit for credential reads and changes; statement and parameter
-- logging remain disabled in the cluster parameters.
GRANT SELECT (access_token), UPDATE (access_token) ON public.users TO auditor;
GRANT SELECT ("key") ON public.tokens TO auditor;
GRANT SELECT ON public.pat_change_audit TO auditor;
-- The app owns users for migrations. Prevent it disabling/removing these two
-- triggers while allowing ordinary column/index migrations. Superuser access
-- remains outside this guarantee and must be audited separately.
CREATE OR REPLACE FUNCTION public.protect_pat_capture() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF session_user = 'postgres' THEN RETURN; END IF;
  -- Checking names alone permits CREATE OR REPLACE TRIGGER to install a no-op.
  -- Validate the function, firing conditions and updated column as well.
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.users'::regclass
      AND tgenabled IN ('O','A') AND NOT tgisinternal
      AND tgfoid = 'public.capture_pat_change()'::regprocedure
      AND tgqual IS NULL AND tgnargs = 0
      AND ((tgname = 'evidence_pat_insert' AND tgtype = 5 AND tgattr = ''::int2vector)
        OR (tgname = 'evidence_pat_update' AND tgtype = 17
          AND tgattr::text = (SELECT attnum::text FROM pg_attribute
            WHERE attrelid = 'public.users'::regclass AND attname = 'access_token' AND NOT attisdropped)))) <> 2 THEN
    RAISE EXCEPTION 'PAT audit trigger definitions require database administrator maintenance';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_pat_capture() FROM PUBLIC, newapi;
DROP EVENT TRIGGER IF EXISTS evidence_protect_pat_capture;
CREATE EVENT TRIGGER evidence_protect_pat_capture ON ddl_command_end
  EXECUTE FUNCTION public.protect_pat_capture();
COMMIT;
