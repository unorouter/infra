-- Least-privilege for the `ip_retention` role (infra/databases/ip-retention.yaml).
--
-- The role does exactly one thing: blank logs.ip on rows older than 30 days. It is
-- declared in new-api/k8s/pg.yaml (managed.roles, password from OpenBao
-- secret/newapi-pg-ip-retention via ESO). CNPG reconciles the role, not its grants,
-- so this script is the whole of what the role can do. Re-apply after a cluster
-- built from initdb (a physical restore keeps grants), same as reader-least-privilege.sql.
--
-- Column-scoped on purpose: SELECT on the three columns the batching query reads,
-- UPDATE on ip, nothing else. No DELETE on any table. logs also carries quota,
-- prompt_tokens, completion_tokens and model_name, the usage records behind every
-- invoice (kept for the § 147 AO period); a role that cannot delete a row cannot lose
-- them, whatever the job's SQL says.

BEGIN;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ip_retention;
GRANT USAGE ON SCHEMA public TO ip_retention;
GRANT SELECT ("id", "created_at", "ip"), UPDATE ("ip") ON public.logs TO ip_retention;

COMMIT;

-- Verify, expected t | f | f | f:
-- SELECT has_column_privilege('ip_retention', 'public.logs', 'ip', 'UPDATE'),
--        has_table_privilege('ip_retention', 'public.logs', 'DELETE'),
--        has_column_privilege('ip_retention', 'public.logs', 'username', 'SELECT'),
--        has_table_privilege('ip_retention', 'public.users', 'SELECT');
