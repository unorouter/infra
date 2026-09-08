#!/usr/bin/env bash
# OpenBao login from the Teleport session, no Dex round trip.
#   ./scripts/bao-login.sh          reader: kv-read, 24h (build-local, dev-env, sops-env)
#   ./scripts/bao-login.sh admin    full admin policy, 1h (kv patch, policy and auth changes)
# The proxy signs a JWT for every app request; the `openbao-jwt` app echoes it back and
# auth/jwt-teleport (bound to that app's audience and the `editor` Teleport role) trades it
# for a token. Token lands in ~/.bao-token like `bao login` does.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}"
ROLE="${1:-reader}"
PORT="${BAO_JWT_PORT:-18201}"

tsh status >/dev/null 2>&1 || { echo "!! no Teleport session: tsh login --proxy=teleport.unorouter.com:443 --auth=github" >&2; exit 1; }
systemctl --user is-active -q tsh-openbao || systemctl --user start tsh-openbao

tsh app login openbao-jwt >/dev/null 2>&1
tsh proxy app openbao-jwt --port "$PORT" >/dev/null 2>&1 &
PROXY=$!
trap 'kill "$PROXY" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 0.25; done

JWT=$(curl -s -m 10 "http://127.0.0.1:$PORT/" | sed -n 's/^Teleport-Jwt-Assertion: //Ip' | tr -d '\r')
[ -n "$JWT" ] || { echo "!! openbao-jwt returned no Teleport-Jwt-Assertion" >&2; exit 1; }

printf '%s' "$JWT" | bao write -field=token "auth/jwt-teleport/login" role="$ROLE" jwt=- | bao login -no-print -
bao token lookup -format=json | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("OpenBao:",d["display_name"],d["policies"],"ttl %dh" % (d["ttl"]//3600 or 1))'
