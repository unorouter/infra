#!/usr/bin/env bash
# OpenBao from the Teleport session, no Dex round trip.
#   ./scripts/bao.sh login          reader: kv-read, 24h (dev-env, sops, reads)
#   ./scripts/bao.sh login admin    full admin policy, 1h (kv patch, policy and auth changes)
#   ./scripts/bao.sh dev-env        write ../unorouter/.env for local development
#   . scripts/bao.sh sops           daily age key into this shell for `sops -d` of edge rules
# BAO_ADDR is the Teleport app proxy (systemd --user tsh-openbao); the token lands in
# ~/.bao-token like `bao login` does, so the audit log names a person.
export PATH="$HOME/.local/bin:$PATH"
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}"

session() {
  bao token lookup >/dev/null 2>&1 && return 0
  echo "!! no OpenBao session: systemctl --user start tsh-openbao; ./scripts/bao.sh login (reader 24h, admin 1h for writes)" >&2
  return 1
}

# The proxy signs a JWT for every app request; the `openbao-jwt` app echoes it back and
# auth/jwt-teleport (bound to that app's audience and the `editor` Teleport role) trades it
# for a token.
login() {
  set -euo pipefail
  local role="${1:-reader}" port="${BAO_JWT_PORT:-18201}" proxy jwt
  tsh status >/dev/null 2>&1 || { echo "!! no Teleport session: tsh login --proxy=teleport.unorouter.com:443 --auth=github" >&2; exit 1; }
  systemctl --user is-active -q tsh-openbao || systemctl --user start tsh-openbao
  tsh app login openbao-jwt >/dev/null 2>&1
  tsh proxy app openbao-jwt --port "$port" >/dev/null 2>&1 &
  proxy=$!
  trap "kill $proxy 2>/dev/null || true" EXIT
  for _ in $(seq 1 40); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/health" && break; sleep 0.25; done
  jwt=$(curl -s -m 10 "http://127.0.0.1:$port/" | sed -n 's/^Teleport-Jwt-Assertion: //Ip' | tr -d '\r')
  [ -n "$jwt" ] || { echo "!! openbao-jwt returned no Teleport-Jwt-Assertion" >&2; exit 1; }
  printf '%s' "$jwt" | bao write -field=token "auth/jwt-teleport/login" role="$role" jwt=- | bao login -no-print -
  bao token lookup -format=json | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("OpenBao:",d["display_name"],d["policies"],"ttl %dh" % (d["ttl"]//3600 or 1))'
}

# The vault holds the value prod uses, INTERNAL_API_URL=http://new-api.services.svc.cluster.local:3000,
# a ClusterIP that resolves nowhere on a laptop: rewrite it to the public route of the same service.
dev_env() {
  set -euo pipefail
  local src; src="$(cd "$(dirname "$0")/../.." && pwd)/unorouter"
  [ -f "$src/.env.public" ] || { echo "no $src/.env.public" >&2; exit 1; }
  session || exit 1
  cp "$src/.env.public" "$src/.env"
  bao kv get -format=json secret/unorouter-env | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]["data"]
d["INTERNAL_API_URL"] = d.get("NEXT_PUBLIC_API_URL", "https://api.unorouter.com")
print("\n".join(f"{k}={v}" for k, v in sorted(d.items()) if not k.startswith("NEXT_PUBLIC_")))
' >> "$src/.env"
  echo ">> wrote $src/.env ($(wc -l < "$src/.env") vars)"
  echo "   INTERNAL_API_URL=$(grep '^INTERNAL_API_URL=' "$src/.env" | cut -d= -f2-)"
}

# Break-glass files (secrets/openbao-init, secrets/tailnet-lock) use the other key, which is
# only on the VeraCrypt volume: export SOPS_AGE_KEY_FILE=/run/media/veracrypt1/unorouter/sops-age-keys.txt
sops_key() {
  session || return 1
  SOPS_AGE_KEY=$(bao kv get -field=key secret/sops-age) || return 1
  export SOPS_AGE_KEY
  unset SOPS_AGE_KEY_FILE
  echo "sops daily key loaded from OpenBao"
}

case "${1:-}" in
  login) shift; login "$@" ;;
  dev-env) dev_env ;;
  sops)
    if (return 0 2>/dev/null); then sops_key; else echo "!! source it so the key stays in your shell: . scripts/bao.sh sops" >&2; exit 1; fi ;;
  *) sed -n '2,6p' "${BASH_SOURCE[0]}" >&2; (return 0 2>/dev/null) || exit 1 ;;
esac
