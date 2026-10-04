-- Least-privilege for the `ip_retention` role (infra/databases/postgres/ip-retention.yaml).
--
-- The role does exactly one thing: blank users.register_ip older than 30 days. It is
-- declared in new-api/k8s/pg.yaml (managed.roles, password from OpenBao
-- secret/newapi-pg-ip-retention via ESO). CNPG reconciles the role, not its grants,
-- so this script is the whole of what the role can do. Re-apply after a cluster
-- built from initdb (a physical restore keeps grants), same as reader-least-privilege.sql.
--
-- Column-scoped on purpose: SELECT on the columns the batching query reads, UPDATE on
-- register_ip, nothing else. No DELETE on any table. logs.ip is ClickHouse's now (a
-- column TTL), and the REVOKE below also takes back the old grant on public.logs.

BEGIN;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ip_retention;
GRANT USAGE ON SCHEMA public TO ip_retention;
-- register_ip_hash is SELECT only: the job reads it as an
-- interlock (never blank an address whose marker is missing) and must never be able to
-- write it, or a bug here could erase what the abuse caps compare on.
GRANT SELECT ("id", "created_at", "register_ip", "register_ip_hash"), UPDATE ("register_ip") ON public.users TO ip_retention;

COMMIT;

-- Verify, expected f | f | t | f | f:
-- SELECT has_column_privilege('ip_retention', 'public.logs', 'ip', 'UPDATE'),
--        has_table_privilege('ip_retention', 'public.logs', 'DELETE'),
--        has_column_privilege('ip_retention', 'public.users', 'register_ip', 'UPDATE'),
--        has_column_privilege('ip_retention', 'public.users', 'register_ip_hash', 'UPDATE'),
--        has_column_privilege('ip_retention', 'public.users', 'email', 'SELECT');
