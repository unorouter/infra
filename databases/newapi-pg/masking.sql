-- options secret-value hiding for the Teleport `reader` role (new-api options table).
-- Apply ONCE after the don->CNPG data import (P2). Idempotent. Rides the physical S3 backup
-- on DR (schema object) -- no re-run needed after restore.
--
-- MODEL: Row Level Security (NOT a view, NOT column REVOKE). Verified on real data.
-- reader has pg_read_all_data (browses users/channels/etc normally) BUT an RLS policy on
-- `options` hides the secret-key ROWS. pg_read_all_data does NOT bypass RLS (only a BYPASSRLS
-- role does, which reader must never have). App/owner bypasses RLS as table owner -> sees all.
--
-- WHY NOT the earlier view+REVOKE: pg_read_all_data SILENTLY BYPASSES table REVOKEs, so a
-- REVOKE SELECT ON options leaked the real value via the base table. RLS is bypass-proof.
-- Scope: defends against the Teleport reader role only; superuser/BYPASSRLS still read all.

-- secret key list (edit here; the RLS policy reads it live)
CREATE TABLE IF NOT EXISTS secret_keys (key text PRIMARY KEY);
INSERT INTO secret_keys (key) VALUES
  ('CreemApiKey'), ('CreemWebhookSecret'), ('discord.client_secret'),
  ('GitHubClientSecret'), ('ModerationApiKey'), ('NowPaymentsApiKey'),
  ('NowPaymentsIpnSecret'), ('NowPaymentsPassword'), ('SMTPToken'),
  ('StripeApiSecret'), ('StripeWebhookSecret'), ('TurnstileSecretKey')
ON CONFLICT DO NOTHING;

-- RLS: reader sees every options row EXCEPT the secret keys. Owner/app unaffected.
ALTER TABLE options ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reader_hide_secrets ON options;
CREATE POLICY reader_hide_secrets ON options FOR SELECT TO reader
  USING (key NOT IN (SELECT key FROM secret_keys));
