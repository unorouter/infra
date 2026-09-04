#!/usr/bin/env bash
# Write unorouter/.env for LOCAL development from OpenBao.
# Usage: ./scripts/dev-env.sh
#
# The vault holds the value prod uses, and prod runs inside the cluster:
#   INTERNAL_API_URL=http://new-api.services.svc.cluster.local:3000
# That is a ClusterIP, so on a laptop every server-side fetch dies with ENOTFOUND. This
# rewrites it to the public route -- same service, reachable from anywhere. build-local.sh
# does the same for the build container, which is also outside the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG="$PWD/kubeconfig"

SRC="$(cd .. && pwd)/unorouter"
[ -f "$SRC/.env.public" ] || { echo "no $SRC/.env.public" >&2; exit 1; }

BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')

cp "$SRC/.env.public" "$SRC/.env"
printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- \
  sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && bao kv get -format=json secret/unorouter-env' \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]["data"]
d["INTERNAL_API_URL"] = d.get("NEXT_PUBLIC_API_URL", "https://api.unorouter.com")
# NEXT_PUBLIC_* already came from .env.public
print("\n".join(f"{k}={v}" for k, v in sorted(d.items()) if not k.startswith("NEXT_PUBLIC_")))
' >> "$SRC/.env"

echo ">> wrote $SRC/.env ($(wc -l < "$SRC/.env") vars)"
echo "   INTERNAL_API_URL=$(grep '^INTERNAL_API_URL=' "$SRC/.env" | cut -d= -f2-)"
