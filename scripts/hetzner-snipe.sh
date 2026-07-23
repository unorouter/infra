#!/usr/bin/env bash
# Hetzner budget-node SNIPER. Loops; the instant a watched cheap type is in stock in an
# eu-central DC it GRABS ONE parked spare server (raw API, ubuntu, on the private net,
# behind the cluster firewall) and stops. Does NOT touch node1/2/3, does NOT join or swap
# anything -- it only wins the capacity race. You do the drain/swap manually afterward
# (runbook rules). The spare costs ~EUR0.01-0.02/hr while parked; delete it if unused.
#
# Preference order (cheapest reliable first): cx23 cx33 (Intel) then cax11 cax21 (ARM;
# NOTE ARM needs the unorouter arm64 image before it can run the frontend) then cx22.
set -uo pipefail
source /home/zero/MEGA/Projects/ai-api/infra/tofu/.env
TOK="$TF_VAR_hcloud_token"
API="https://api.hetzner.cloud/v1"

SSH_KEY=115608845          # unorouter-operator
NETWORK=12478474           # unorouter-cluster (10.100.0.0/16)
FIREWALL=11352641          # unorouter-node
SPARE_IP=10.100.1.10       # parked spare private IP (outside node1-3's .1-.3)
SPARE_NAME=unorouter-spare
PREF="cx23 cx33 cx22 cax11 cax21"   # try in this order

hc(){ curl -s -H "Authorization: Bearer $TOK" "$@"; }

while true; do
  # {type: [locations]} of watched types in stock, eu-central only
  PICK=$(python3 - "$PREF" <<'EOF'
import json,urllib.request,os,sys
tok=os.environ["TF_VAR_hcloud_token"]
pref=sys.argv[1].split()
def get(u):
    r=urllib.request.Request(u,headers={"Authorization":"Bearer "+tok})
    return json.load(urllib.request.urlopen(r,timeout=20))
types={t['id']:t['name'] for t in get("https://api.hetzner.cloud/v1/server_types?per_page=50")['server_types']}
stock={}  # name -> first eu-central dc that has it
for dc in get("https://api.hetzner.cloud/v1/datacenters")['datacenters']:
    if dc['location']['network_zone']!='eu-central': continue
    for i in dc['server_types']['available']:
        n=types.get(i,'')
        stock.setdefault(n, dc['name'])
for t in pref:
    if t in stock:
        print(f"{t} {stock[t]}"); break
EOF
)

  if [ -z "$PICK" ]; then
    echo "$(date -Is) no stock (sniping: $PREF in eu-central)"
    sleep 60; continue
  fi

  TYPE=$(echo "$PICK" | awk '{print $1}')
  DC=$(echo "$PICK" | awk '{print $2}')
  LOC=$(echo "$DC" | cut -d- -f1)     # nbg1-dc3 -> nbg1
  echo "$(date -Is) STOCK: $TYPE @ $DC -- grabbing parked spare $SPARE_NAME..."

  RESP=$(hc -X POST "$API/servers" -H "Content-Type: application/json" -d "{
    \"name\": \"$SPARE_NAME\",
    \"server_type\": \"$TYPE\",
    \"image\": \"ubuntu-24.04\",
    \"location\": \"$LOC\",
    \"ssh_keys\": [$SSH_KEY],
    \"firewalls\": [{\"firewall\": $FIREWALL}],
    \"networks\": [$NETWORK],
    \"start_after_create\": true
  }")

  if echo "$RESP" | grep -q '"server"'; then
    SID=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['id'])")
    IP=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])")
    echo "$(date -Is) SNIPED: $SPARE_NAME id=$SID type=$TYPE ip=$IP dc=$DC" | tee -a /home/zero/.local/state/hetzner-snipe.log
    DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
      notify-send -u critical "Hetzner SNIPED!" "$TYPE @ $DC secured (id $SID, $IP). Do the swap manually." 2>/dev/null || true
    echo ">>> spare secured. Assign private IP $SPARE_IP + incorporate manually per runbook. Sniper exiting."
    exit 0
  else
    echo "$(date -Is) grab FAILED (raced out or error): $(echo "$RESP" | head -c 200)"
    sleep 20
  fi
done
