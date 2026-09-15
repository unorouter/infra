-- Records every INCREASE to users.quota, whatever wrote it, in a table the
-- application role cannot rewrite.
--
-- Motivation: user 8363 (jiiajdch) held exactly $3,000.00 (quota 2706.02 +
-- used 293.98) with no topup, redemption, referral or admin-grant row behind
-- it. Quota auditing in the application has existed since 2026-06-12 and the
-- account registered 2026-07-22, so every Go path that grants a balance would
-- have logged it. That leaves a write that bypassed those helpers, or a
-- deleted log row. This addresses both.
--
-- An application-level hook only observes callers that go through the
-- application, so it cannot see the first case. A trigger observes the write
-- itself: raw SQL, a psql session, a migration, an ORM path nobody audited.
--
-- The second case is why ownership matters. `logs` is owned by the app role,
-- so anything able to reach the database as that role can erase its own trail
-- with a DELETE. This table is owned by postgres and the app role is granted
-- INSERT only: it can append through the trigger and cannot UPDATE, DELETE or
-- TRUNCATE. Tampering therefore requires superuser, which the application
-- never uses. That is a meaningful raise, not a guarantee -- a superuser can
-- still rewrite anything, so treat this as tamper-EVIDENT for the app role,
-- not tamper-proof in general. Shipping backups off-box is what covers the
-- superuser case.
--
-- Increases only. Settlement decrements quota on roughly 9k requests an hour,
-- so logging every write would add ~200k rows a day and bury the handful that
-- matter; a balance going DOWN is also not how an account gets funded. Refunds
-- come back through this path, so expect legitimate small increases from
-- streamed requests returning unused pre-consumed quota.
--
-- Deliberately NOT in the Go migrations: this is Postgres-specific and new-api
-- must build against SQLite and MySQL too (CLAUDE.md Rule 2). It is also
-- append-only and never read by the application, so it cannot affect a request.

CREATE TABLE IF NOT EXISTS quota_audit (
  id          bigserial PRIMARY KEY,
  user_id     bigint      NOT NULL,
  old_quota   bigint      NOT NULL,
  new_quota   bigint      NOT NULL,
  delta       bigint      NOT NULL,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  -- session_user, not current_user: the trigger function is SECURITY DEFINER
  -- (it must be, so the app role can append to a table it does not own), and
  -- that makes current_user the function owner for every row, which would
  -- record "postgres" no matter who connected. session_user survives both
  -- SECURITY DEFINER and SET ROLE, so it still separates application traffic
  -- from a human psql session -- the distinction that matters when a balance
  -- has no application-level record.
  db_user     text        NOT NULL,
  app_name    text,
  client_addr inet
);

-- Reconciliation queries are "recent grants" and "history for one account".
CREATE INDEX IF NOT EXISTS idx_quota_audit_changed_at ON quota_audit (changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_quota_audit_user_id ON quota_audit (user_id, changed_at DESC);

-- SECURITY DEFINER so the trigger can insert on behalf of a role that holds no
-- write privilege on this table; that asymmetry is the whole protection. The
-- search_path is pinned because a SECURITY DEFINER function without one can be
-- hijacked by a caller-controlled schema.
CREATE OR REPLACE FUNCTION log_quota_increase() RETURNS trigger AS $$
BEGIN
  INSERT INTO quota_audit (user_id, old_quota, new_quota, delta, db_user, app_name, client_addr)
  VALUES (NEW.id, OLD.quota, NEW.quota, NEW.quota - OLD.quota,
          session_user, current_setting('application_name', true), inet_client_addr());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Only postgres may execute it directly; the trigger path is unaffected.
REVOKE ALL ON FUNCTION log_quota_increase() FROM PUBLIC;

-- Append-only for the application: the trigger needs INSERT, and withholding
-- UPDATE/DELETE/TRUNCATE is what stops a compromised app role from erasing the
-- evidence of its own writes. The sequence grant is required for bigserial.
GRANT INSERT ON quota_audit TO newapi;
GRANT USAGE, SELECT ON SEQUENCE quota_audit_id_seq TO newapi;
REVOKE UPDATE, DELETE, TRUNCATE ON quota_audit FROM newapi;

-- WHEN filters in the trigger definition, so a decrement never enters the
-- function at all: no per-settlement function-call overhead on the hot path.
DROP TRIGGER IF EXISTS trg_quota_increase ON users;
CREATE TRIGGER trg_quota_increase
  AFTER UPDATE OF quota ON users
  FOR EACH ROW
  WHEN (NEW.quota > OLD.quota)
  EXECUTE FUNCTION log_quota_increase();

-- Withholding DELETE is not enough on its own: the app role owns `users`, so
-- it can DROP the trigger and then grant a balance with nothing watching.
-- Verified: after a drop, a +999 left no row. Taking ownership of `users` away
-- would close it too, but the application runs AutoMigrate(&User{}) on every
-- boot and needs DDL there, so an event trigger is used instead -- it blocks
-- exactly this one drop and leaves ordinary migrations alone (ALTER TABLE
-- ADD/DROP COLUMN still succeed as the app role).
CREATE OR REPLACE FUNCTION protect_quota_audit_trigger() RETURNS event_trigger AS $$
DECLARE obj record;
BEGIN
  -- session_user, so SECURITY DEFINER and SET ROLE cannot spoof their way past.
  IF session_user = 'postgres' THEN RETURN; END IF;
  FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
    IF obj.object_type = 'trigger' AND obj.object_identity LIKE 'trg_quota_increase%' THEN
      RAISE EXCEPTION 'dropping trg_quota_increase requires superuser';
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

DROP EVENT TRIGGER IF EXISTS trg_protect_quota_audit;
CREATE EVENT TRIGGER trg_protect_quota_audit ON sql_drop
  EXECUTE FUNCTION protect_quota_audit_trigger();
