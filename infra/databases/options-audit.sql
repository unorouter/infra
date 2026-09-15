-- pgaudit object logging for `options`, the one table that holds every third-party
-- secret (payment processors, OAuth apps, SMTP, Turnstile).
--
-- Added 2026-09-06 after the Creem merchant key was used by a third party and no log
-- on the DB side could say whether the table had been read. pgaudit's object mode logs
-- every statement that touches a relation the audit role holds privileges on, whoever
-- runs it, so a SELECT on options by any login role now lands in the postgres log with
-- user, database and statement. pgaudit.log is `none` in the cluster parameters so
-- nothing else is logged. The cluster parameters (pgaudit.role, log_connections) live
-- in new-api/k8s/pg.yaml; this file is the DDL half and must be re-applied after a
-- restore.

CREATE EXTENSION IF NOT EXISTS pgaudit;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor') THEN
    CREATE ROLE auditor NOLOGIN;
  END IF;
END
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.options TO auditor;
