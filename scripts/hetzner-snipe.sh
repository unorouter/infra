#!/usr/bin/env bash
# Hetzner budget-node SNIPER. The fleet is three cx43s, but node8 and node10 both sit in
# hel1, so a hel1 outage would cost quorum. This watches cx43 stock in fsn1 and grabs one
# parked spare the moment it appears, to restore the 3-DC spread on the next swap. It does
# NOT touch live nodes and does NOT join anything -- it only wins the capacity race. Swaps
# are manual per the canonical runbook (bootstrap/dr/README.md "Node swap").
#
# Parked spare costs ~EUR0.03/hr; cx43 = 8c/16GB/160GB EUR15.99/mo gross once kept.
set -uo pipefail
source /home/zero/MEGA/Projects/ai-api/infra/tofu/.env
TOK="$TF_VAR_hcloud_token"
API="https://api.hetzner.cloud/v1"

SSH_KEY=115608845          # unorouter-operator
NETWORK=12478474           # unorouter-cluster (10.100.0.0/16)
FIREWALL=11352641          # unorouter-node
TYPE=cx43
LOCS="fsn1"           # node8+node10 are both hel1, node9 is nbg1: fsn1 restores the 3-DC spread
LOG=/home/zero/.local/state/hetzner-snipe.log

hc(){ curl -s -H "Authorization: Bearer $TOK" "$@"; }

have(){ # spare already exists for this location?
  hc "$API/servers?name=unorouter-spare-$1" | grep -q '"unorouter-spare-'"$1"'"'
}

grab(){
  local loc=$1
  local resp
  resp=$(hc -X POST "$API/servers" -H "Content-Type: application/json" -d "{
    \"name\": \"unorouter-spare-$loc\",
    \"server_type\": \"$TYPE\",
    \"image\": \"ubuntu-24.04\",
    \"location\": \"$loc\",
    \"ssh_keys\": [$SSH_KEY],
    \"firewalls\": [{\"firewall\": $FIREWALL}],
    \"networks\": [$NETWORK],
    \"start_after_create\": true
  }")
  if echo "$resp" | grep -q '"server"'; then
    local sid ip
    sid=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['id'])")
    ip=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])")
    echo "$(date -Is) SNIPED: unorouter-spare-$loc id=$sid type=$TYPE ip=$ip" | tee -a "$LOG"
    DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
      notify-send -u critical "Hetzner SNIPED!" "$TYPE @ $loc secured (id $sid, $ip). Swap manually per runbook." 2>/dev/null || true
    return 0
  fi
  echo "$(date -Is) grab FAILED @ $loc: $(echo "$resp" | head -c 200)"
  return 1
}

while true; do
  MISSING=""
  for loc in $LOCS; do have "$loc" || MISSING="$MISSING $loc"; done
  if [ -z "$MISSING" ]; then
    echo "$(date -Is) Spare secured. Sniper exiting." | tee -a "$LOG"
    DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
      notify-send -u critical "Hetzner sniper DONE" "cx43 spare parked in fsn1. Swap a hel1 node per the runbook." 2>/dev/null || true
    exit 0
  fi

  # locations where cx43 is in stock right now
  STOCK=$(python3 - "$TYPE" <<'EOF'
import json,urllib.request,os,sys
tok=os.environ["TF_VAR_hcloud_token"]
want=sys.argv[1]
def get(u):
    r=urllib.request.Request(u,headers={"Authorization":"Bearer "+tok})
    return json.load(urllib.request.urlopen(r,timeout=20))
types={t['id']:t['name'] for t in get("https://api.hetzner.cloud/v1/server_types?per_page=50")['server_types']}
for dc in get("https://api.hetzner.cloud/v1/datacenters")['datacenters']:
    if dc['location']['network_zone']!='eu-central': continue
    if any(types.get(i)==want for i in dc['server_types']['available']):
        print(dc['location']['name'])
EOF
)
  GOT=0
  for loc in $MISSING; do
    if echo "$STOCK" | grep -qx "$loc"; then
      grab "$loc" && GOT=1
    fi
  done
  [ "$GOT" = 1 ] && continue   # re-check immediately, stock windows are short
  echo "$(date -Is) waiting: need${MISSING}, in stock: $(echo $STOCK | tr '\n' ' ')"
  sleep 60
done
