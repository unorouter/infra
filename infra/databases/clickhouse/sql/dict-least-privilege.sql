-- Least-privilege for the `clickhouse_dict` role: ClickHouse's two dictionaries
-- (clickhouse/sql/security.sql) read newapi-pg through it, from the -ro service.
--
-- Declared like ip_retention in new-api/k8s/pg.yaml managed.roles (login, password
-- from OpenBao secret/newapi-pg-clickhouse-dict, connectionLimit 2, inRoles []), so it
-- takes CNPG's trailing scram rule. CNPG reconciles the role, not its grants, so this
-- script is all it can do. Re-apply after a cluster built from initdb.
--
-- tokens: id and user_id only, never `key`. users: the balance and the seven identity
-- columns HasIdentity checks, never password, access_token, email or setting. The
-- dictionary query folds the identity columns into one flag inside Postgres.

BEGIN;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM clickhouse_dict;
GRANT USAGE ON SCHEMA public TO clickhouse_dict;
GRANT SELECT ("id", "user_id") ON public.tokens TO clickhouse_dict;
GRANT SELECT ("id", "quota", "github_id", "discord_id", "oidc_id", "telegram_id",
              "linux_do_id", "wechat_id", "google_id") ON public.users TO clickhouse_dict;

COMMIT;

-- Verify, expected t | f | t | f | f:
-- SELECT has_column_privilege('clickhouse_dict', 'public.tokens', 'user_id', 'SELECT'),
--        has_column_privilege('clickhouse_dict', 'public.tokens', 'key', 'SELECT'),
--        has_column_privilege('clickhouse_dict', 'public.users', 'quota', 'SELECT'),
--        has_column_privilege('clickhouse_dict', 'public.users', 'password', 'SELECT'),
--        has_table_privilege('clickhouse_dict', 'public.logs', 'SELECT');

-- The one-time copy of the gateway's history into ClickHouse (docs/operations.md, log store)
-- needs every column of logs and audit_logs, and only while it runs:
--   GRANT SELECT ON public.logs, public.audit_logs TO clickhouse_dict;
-- and afterwards, so the role is back to the two dictionaries:
--   REVOKE SELECT ON public.logs, public.audit_logs FROM clickhouse_dict;
