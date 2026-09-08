#!/usr/bin/env bash
# Recreate the GitHub-OIDC auth path that lets CI read build secrets from OpenBao.
# Idempotent: safe to re-run.
#
# A raft snapshot restore already carries this. Run it only when OpenBao was rebuilt from
# scratch (no snapshot), otherwise CI fails at "Fetch build secrets from OpenBao" with a
# 403 and every image build stops.
#
# The cloudflared route (openbao-ci.unorouter.com) IS in git -- infra/cloudflared.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/teleport-unorouter.yaml}"

export PATH="$HOME/.local/bin:$PATH"   # bao, tsh, tctl live there
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}"   # Teleport app proxy, OIDC token in ~/.bao-token
bao token lookup >/dev/null 2>&1 || { echo "!! no OpenBao session: systemctl --user start tsh-openbao; ./scripts/bao-login.sh admin (writes, 1h token)" >&2; exit 1; }
BAO() { sh -c "$*"; }

echo ">> jwt auth mount trusting GitHub's OIDC provider"
BAO "bao auth enable -path=jwt-github jwt" 2>/dev/null || echo "   (already enabled)"
BAO "bao write auth/jwt-github/config \
  oidc_discovery_url=https://token.actions.githubusercontent.com \
  bound_issuer=https://token.actions.githubusercontent.com" >/dev/null

echo ">> ci-unorouter policy (read, one path)"
bao policy write ci-unorouter - <<'EOF' >/dev/null
path "secret/data/unorouter-env" {
  capabilities = ["read"]
}
EOF

echo ">> unorouter-ci role bound to the repo"
# bound_claims is what makes the public endpoint safe: a JWT from any other repository is
# rejected, so possession of the URL grants nothing. The ref binding keeps a branch with
# an edited workflow (any collaborator can push one) from reading the build secrets.
bao write auth/jwt-github/role/unorouter-ci - <<'EOF' >/dev/null
{
  "role_type": "jwt",
  "user_claim": "workflow",
  "bound_audiences": ["https://github.com/unorouter"],
  "bound_claims": { "repository": "unorouter/unorouter", "ref": "refs/heads/main" },
  "token_policies": ["ci-unorouter"],
  "token_ttl": "10m",
  "token_max_ttl": "20m"
}
EOF

echo ">> verify"
BAO "bao read auth/jwt-github/role/unorouter-ci" | grep -E "bound_claims|token_policies|token_ttl"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://openbao-ci.unorouter.com/v1/sys/health || true)
echo "   openbao-ci endpoint: HTTP $code (200 = reachable; 302 means it is behind Teleport and CI cannot use it)"
