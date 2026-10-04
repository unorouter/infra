-- Skip indexes on the gateway's ClickHouse logs table, hand-applied as admin after the
-- gateway has created it (the gateway user has no ALTER). The sort key is
-- (created_at, request_id), so lookups by token, user or request id scanned every part:
-- 17M to 22M rows and up to 4.5 s each on 2026-10-04, enough concurrent ones to hit the
-- server memory limit. Postgres had B-tree indexes on all four.
ALTER TABLE new_api_logs.logs ADD INDEX IF NOT EXISTS idx_token_id token_id TYPE bloom_filter(0.01) GRANULARITY 1;
ALTER TABLE new_api_logs.logs ADD INDEX IF NOT EXISTS idx_user_id user_id TYPE bloom_filter(0.01) GRANULARITY 1;
ALTER TABLE new_api_logs.logs ADD INDEX IF NOT EXISTS idx_request_id request_id TYPE bloom_filter(0.001) GRANULARITY 1;
ALTER TABLE new_api_logs.logs ADD INDEX IF NOT EXISTS idx_upstream_request_id upstream_request_id TYPE bloom_filter(0.001) GRANULARITY 1;
-- Existing parts only get the indexes when materialized; new parts get them on insert.
ALTER TABLE new_api_logs.logs MATERIALIZE INDEX idx_token_id;
ALTER TABLE new_api_logs.logs MATERIALIZE INDEX idx_user_id;
ALTER TABLE new_api_logs.logs MATERIALIZE INDEX idx_request_id;
ALTER TABLE new_api_logs.logs MATERIALIZE INDEX idx_upstream_request_id;
