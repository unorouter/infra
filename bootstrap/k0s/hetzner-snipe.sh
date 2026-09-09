#!/usr/bin/env bash
# Hetzner capacity sniper. Watches stock for one server type across the EU locations and buys
# up to SNIPE_COUNT parked spares the moment they appear (cx43 is chronically sold out). It
# never touches live nodes, never joins anything and holds no other credential than the
# Hetzner token: a spare is a plain Ubuntu box behind the node firewall until an operator
# joins it by hand (bootstrap/k0s/spare-join.sh). Spares are named
# <prefix>-<location>-<n> and carry the label role=spare. Runs as a systemd unit on the
# operator VPS; secrets come from /etc/hetzner-snipe/env (HCLOUD_TOKEN, DISCORD_WEBHOOK).
#
#   SNIPE_TYPE    server type to hunt                      (default cx43)
#   SNIPE_LOCS    locations in order of preference         (default "fsn1 nbg1 hel1")
#   SNIPE_COUNT   how many spares to hold in total         (default 1)
#   SNIPE_PREFIX  server name prefix                       (default unorouter-spare)
set -uo pipefail
set -a
source "${SNIPE_ENV:-/etc/hetzner-snipe/env}"
set +a
API="https://api.hetzner.cloud/v1"

SSH_KEY=115608845          # unorouter-operator
NETWORK=12478474           # unorouter-cluster (10.100.0.0/16)
FIREWALL=11352641          # unorouter-node
TYPE="${SNIPE_TYPE:-cx43}"
LOCS="${SNIPE_LOCS:-fsn1 nbg1 hel1}"
TARGET="${SNIPE_COUNT:-1}"
PREFIX="${SNIPE_PREFIX:-unorouter-spare}"

hc(){ curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "$@"; }

notify(){
  [ -n "${DISCORD_WEBHOOK:-}" ] || return 0
  python3 - "$1" <<'PY' || true
import json,os,sys,urllib.request
req=urllib.request.Request(os.environ["DISCORD_WEBHOOK"],
    data=json.dumps({"content":sys.argv[1]}).encode(),
    headers={"Content-Type":"application/json","User-Agent":"unorouter-sniper/1.0"})
try: urllib.request.urlopen(req,timeout=15)
except Exception: pass
PY
}

# how many spares exist right now (by name prefix, so a restart never double-buys)
count(){
  hc "$API/servers?per_page=50" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(sum(1 for s in d.get('servers',[]) if s['name'].startswith('$PREFIX-')))" 2>/dev/null || echo 0
}

grab(){
  local loc=$1 n=$2 name resp sid ip
  name="$PREFIX-$loc-$n"
  resp=$(hc -X POST "$API/servers" -H "Content-Type: application/json" -d "{
    \"name\": \"$name\",
    \"server_type\": \"$TYPE\",
    \"image\": \"ubuntu-24.04\",
    \"location\": \"$loc\",
    \"ssh_keys\": [$SSH_KEY],
    \"firewalls\": [{\"firewall\": $FIREWALL}],
    \"networks\": [$NETWORK],
    \"labels\": {\"role\": \"spare\"},
    \"start_after_create\": true
  }")
  if echo "$resp" | grep -q '"server"'; then
    sid=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['id'])")
    ip=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])")
    echo "$(date -Is) SNIPED $name id=$sid ip=$ip ($n/$TARGET)"
    notify ":dart: **Hetzner sniped $TYPE @ $loc** ($n/$TARGET): \`$name\` id \`$sid\`, ip \`$ip\`. Parked and idle."
    return 0
  fi
  echo "$(date -Is) grab FAILED @ $loc: $(echo "$resp" | head -c 200)"
  return 1
}

while true; do
  HAVE=$(count)
  if [ "$HAVE" -ge "$TARGET" ]; then
    echo "$(date -Is) $HAVE/$TARGET spares parked, exiting"
    notify ":white_check_mark: **Hetzner sniper done**: $HAVE x $TYPE parked ($LOCS)."
    exit 0
  fi

  STOCK=$(python3 - "$TYPE" <<'PY' || true
import json,os,sys,urllib.request
tok=os.environ["HCLOUD_TOKEN"]; want=sys.argv[1]
def get(u):
    r=urllib.request.Request(u,headers={"Authorization":"Bearer "+tok})
    return json.load(urllib.request.urlopen(r,timeout=20))
try:
    types={t['id']:t['name'] for t in get("https://api.hetzner.cloud/v1/server_types?per_page=50")['server_types']}
    for dc in get("https://api.hetzner.cloud/v1/datacenters")['datacenters']:
        if dc['location']['network_zone']!='eu-central': continue
        if any(types.get(i)==want for i in dc['server_types']['available']):
            print(dc['location']['name'])
except Exception:
    pass
PY
)
  GOT=0
  for loc in $LOCS; do
    echo "$STOCK" | grep -qx "$loc" || continue
    while [ "$HAVE" -lt "$TARGET" ]; do
      grab "$loc" "$((HAVE+1))" || break
      HAVE=$((HAVE+1)); GOT=1
    done
    [ "$HAVE" -ge "$TARGET" ] && break
  done
  [ "$GOT" = 1 ] && continue
  echo "$(date -Is) waiting: have $HAVE/$TARGET $TYPE, in stock: $(echo $STOCK | tr '\n' ' ')"
  sleep 60
done
