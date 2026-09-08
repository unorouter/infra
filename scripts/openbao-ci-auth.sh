#!/usr/bin/env bash
# Retire the frontend CI role. Builds use public configuration only.
# Keep an explicit deny so previously issued tokens lose secret access too.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}"
bao token lookup >/dev/null
bao policy write ci-unorouter - <<'POLICY'
path "secret/*" {
  capabilities = ["deny"]
}
POLICY
bao delete auth/jwt-github/role/unorouter-ci
