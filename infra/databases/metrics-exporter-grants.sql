-- The CNPG metrics exporter runs as cnpg_metrics_exporter and is granted SELECT
-- on `logs` only. newapi_token_key_reveals joins `tokens` to tell a self-reveal
-- from a cross-user one, so without this grant the query fails every scrape with
-- "permission denied for table tokens" and the metric disappears entirely.
--
-- That failure is silent in the worst way: CNPG runs the custom queries in one
-- transaction, so a single permission error rolls the batch back and takes other
-- metrics down with it. A critical alert whose metric is absent never fires, and
-- `absent()` only covers the one series SecurityMetricsMissing watches.
--
-- Column-scoped on purpose. The exporter needs id and user_id to compare owner
-- against actor; it must never be able to read `key`, which is the plaintext
-- API key the alert exists to protect. Verified: `select key from tokens` as
-- this role returns permission denied while the metric query succeeds.
GRANT SELECT (id, user_id) ON tokens TO cnpg_metrics_exporter;

-- card top-up velocity (cnpg-security-queries newapi_creem_topup_velocity) needs the account age
GRANT SELECT (id, created_at) ON users TO cnpg_metrics_exporter;
