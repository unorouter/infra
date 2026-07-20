-- options secret-value masking for the Teleport `reader` role (new-api options table).
-- Apply ONCE after the initial don->CNPG data migration (P2). On DR this rides the physical
-- S3 backup and comes back automatically -- re-running is idempotent/harmless.
--
-- Model: reader sees every row; `value` shows '****' for secret keys, real for config keys.
-- Enforcement = owner-rights security-barrier view + revoked base table. App/owner unaffected.
-- Scope: defends against the Teleport `reader` role only; owner/superuser still read plaintext
-- (true fix = move the secret into Vault; P9). See plan "DB secret-value hiding" section.

-- secret key list (edit here, not in the view DDL)
CREATE TABLE IF NOT EXISTS secret_keys (key text PRIMARY KEY);
INSERT INTO secret_keys (key) VALUES
  ('CreemApiKey'), ('CreemWebhookSecret'), ('discord.client_secret'),
  ('GitHubClientSecret'), ('ModerationApiKey'), ('NowPaymentsApiKey'),
  ('NowPaymentsIpnSecret'), ('NowPaymentsPassword'), ('SMTPToken'),
  ('StripeApiSecret'), ('StripeWebhookSecret'), ('TurnstileSecretKey')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW options_masked WITH (security_barrier = true) AS
SELECT
  o.key,
  CASE WHEN EXISTS (SELECT 1 FROM secret_keys s WHERE s.key = o.key)
       THEN '****'
       ELSE o.value
  END AS value
FROM options o;

-- reader reaches ONLY the view; base table + secret_keys revoked. (reader role itself is
-- reconciled by CNPG managed.roles; here we bind privileges.)
REVOKE ALL ON options FROM PUBLIC;
REVOKE ALL ON secret_keys FROM PUBLIC;
REVOKE SELECT ON options FROM reader;
GRANT SELECT ON options_masked TO reader;
