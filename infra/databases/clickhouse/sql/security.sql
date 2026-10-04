-- ClickHouse objects behind clickhouse/security-exporter.yaml, hand-applied as the
-- ClickHouse admin after the gateway has created new_api_logs.logs and
-- new_api_logs.audit_logs. Re-apply after a restore that recreates the database.
--
-- The Postgres tables two queries join (tokens for newapi_token_key_reveals, users
-- for newapi_abuse) are read through dictionaries rather than the postgresql() table
-- function: a table function would open a Postgres connection and copy the table on
-- every scrape, while a dictionary is one bulk read per refresh and an in-memory
-- lookup per row. The owner of a token never changes, and a few minutes of staleness
-- on a balance cannot move a 30 minute alert.
--
-- Both read newapi-pg-ro through the named collection `newapi_pg` (server.xml in
-- clickhouse/clickhouse.yaml), so the password never lands in DDL or in system.dictionaries.
-- The role's Postgres grants are in clickhouse/sql/dict-least-privilege.sql.

-- Owner of every API key. Only id and user_id are declared, so only those two
-- columns are selected; the role cannot read `key` anyway.
CREATE OR REPLACE DICTIONARY new_api_logs.newapi_token_owner (
  id UInt64,
  user_id Int64
)
PRIMARY KEY id
SOURCE(POSTGRESQL(NAME newapi_pg TABLE 'tokens'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- Balance and whether any third-party identity is bound: the same seven columns as
-- RegistrationProvenance.HasIdentity, folded into one flag inside Postgres so the
-- identity ids themselves never reach ClickHouse.
CREATE OR REPLACE DICTIONARY new_api_logs.newapi_user_standing (
  id UInt64,
  quota Int64,
  has_identity UInt8
)
PRIMARY KEY id
SOURCE(POSTGRESQL(NAME newapi_pg QUERY 'SELECT id, quota, (coalesce(github_id, '''') <> '''' OR coalesce(discord_id, '''') <> '''' OR coalesce(oidc_id, '''') <> '''' OR coalesce(telegram_id, '''') <> '''' OR coalesce(linux_do_id, '''') <> '''' OR coalesce(wechat_id, '''') <> '''' OR coalesce(google_id, '''') <> '''')::int AS has_identity FROM public.users'))
LAYOUT(HASHED())
LIFETIME(MIN 60 MAX 120);

-- The exporter's login. Password from OpenBao secret/clickhouse-security-exporter;
-- only its sha256 goes here, typed in at apply time, never committed.
CREATE USER IF NOT EXISTS security_exporter
  IDENTIFIED WITH sha256_hash BY '<sha256 hex of the OpenBao password>'
  DEFAULT DATABASE new_api_logs
  -- readonly 2, not 1: clickhouse-go sends max_execution_time from the scrape
  -- deadline with every query, which readonly 1 refuses.
  SETTINGS readonly = 2, max_execution_time = 30, max_memory_usage = 1000000000 MAX 1000000000;

-- Nothing here can write. logs is column-scoped: its usage columns are not needed.
-- audit_logs is granted whole because a column grant on the JSON `other` does not
-- cover its subcolumns, which the queries read; it holds no secret (token_ref is a
-- sha256 fingerprint).
GRANT SELECT (created_at, type, user_id, username, token_name, ip, content) ON new_api_logs.logs TO security_exporter;
GRANT SELECT ON new_api_logs.audit_logs TO security_exporter;
GRANT dictGet ON new_api_logs.newapi_token_owner TO security_exporter;
GRANT dictGet ON new_api_logs.newapi_user_standing TO security_exporter;

-- Verify as security_exporter: every query in the exporter answers, and
--   SELECT quota FROM new_api_logs.logs LIMIT 1
-- is refused (ACCESS_DENIED).
