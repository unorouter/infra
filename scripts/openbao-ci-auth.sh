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
export KUBECONFIG="$PWD/kubeconfig"

BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')
BAO() { printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- \
  sh -c "read -r BAO_TOKEN && export BAO_TOKEN && $*"; }

echo ">> jwt auth mount trusting GitHub's OIDC provider"
BAO "bao auth enable -path=jwt-github jwt" 2>/dev/null || echo "   (already enabled)"
BAO "bao write auth/jwt-github/config \
  oidc_discovery_url=https://token.actions.githubusercontent.com \
  bound_issuer=https://token.actions.githubusercontent.com" >/dev/null

echo ">> ci-unorouter policy (read, one path)"
printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- sh -c \
  'read -r BAO_TOKEN && export BAO_TOKEN && cat > /tmp/p.hcl <<EOF && bao policy write ci-unorouter /tmp/p.hcl
path "secret/data/unorouter-env" {
  capabilities = ["read"]
}
EOF' >/dev/null

echo ">> unorouter-ci role bound to the repo"
# bound_claims is what makes the public endpoint safe: a JWT from any other repository is
# rejected, so possession of the URL grants nothing.
printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- sh -c \
  'read -r BAO_TOKEN && export BAO_TOKEN && bao write auth/jwt-github/role/unorouter-ci - <<EOF
{
  "role_type": "jwt",
  "user_claim": "workflow",
  "bound_audiences": ["https://github.com/unorouter"],
  "bound_claims": { "repository": "unorouter/unorouter" },
  "token_policies": ["ci-unorouter"],
  "token_ttl": "10m",
  "token_max_ttl": "20m"
}
EOF' >/dev/null

echo ">> verify"
BAO "bao read auth/jwt-github/role/unorouter-ci" | grep -E "bound_claims|token_policies|token_ttl"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://openbao-ci.unorouter.com/v1/sys/health || true)
echo "   openbao-ci endpoint: HTTP $code (200 = reachable; 302 means it is behind Teleport and CI cannot use it)"
