#!/usr/bin/env bash
# Hetzner capacity sniper. Watches stock for one server type in the wanted locations and buys
# the node the moment it appears (cx43 is chronically sold out; since 2026-09-13 the hunt is a
# Falkenstein cx43, the first node outside nbg1). It never touches live nodes. SNIPE_USER_DATA
# is a rendered machine config (talos/README.md "A new node"): the server is created the way
# tofu creates one, config as user data, named after the config's hostname, Hetzner firewall
# attached, and boots straight into the cluster; import it into tofu afterwards. Runs as a
# systemd unit on the operator VPS; secrets come from /etc/hetzner-snipe/env (HCLOUD_TOKEN,
# DISCORD_WEBHOOK) with the config file next to it.
#
#   SNIPE_USER_DATA  rendered machine config to boot with  (required)
#   SNIPE_TYPE       server type to hunt                    (default cx43)
#   SNIPE_LOCS       locations in order of preference       (default "fsn1")
#   SNIPE_IMAGE      image id                               (default: newest snapshot labelled os=talos)
set -uo pipefail
set -a
source "${SNIPE_ENV:-/etc/hetzner-snipe/env}"
set +a
API="https://api.hetzner.cloud/v1"

FIREWALL=11352641          # unorouter-node
TYPE="${SNIPE_TYPE:-cx43}"
LOCS="${SNIPE_LOCS:-fsn1}"
TARGET=1
USER_DATA="${SNIPE_USER_DATA:-}"
[ -n "$USER_DATA" ] && [ -r "$USER_DATA" ] || { echo "usage: SNIPE_USER_DATA=<rendered machine config> $0" >&2; exit 1; }
NODE=$(grep -m1 -E '^\s*hostname:' "$USER_DATA" | awk '{print $2}')
[ -n "$NODE" ] || { echo "no hostname in $USER_DATA" >&2; exit 1; }

hc(){ curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "$@"; }

IMAGE="${SNIPE_IMAGE:-$(hc "$API/images?type=snapshot&label_selector=os=talos&sort=created:desc" | python3 -c "import sys,json; print(json.load(sys.stdin)['images'][0]['id'])")}"
[ -n "$IMAGE" ] || { echo "no os=talos snapshot and no SNIPE_IMAGE" >&2; exit 1; }

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

# how many exist right now (by name, so a restart never double-buys)
count(){
  hc "$API/servers?per_page=50" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(1 if '$NODE' in [s['name'] for s in d.get('servers',[])] else 0)" 2>/dev/null || echo 0
}

grab(){
  local loc=$1 n=$2 name resp sid ip
  name="$NODE"
  resp=$(python3 - "$name" "$TYPE" "$IMAGE" "$loc" "$FIREWALL" "$USER_DATA" <<'PY' | hc -X POST "$API/servers" -H "Content-Type: application/json" -d @-
import json,sys
name,typ,img,loc,fw,ud=sys.argv[1:7]
body={"name":name,"server_type":typ,"image":img,"location":loc,"firewalls":[{"firewall":int(fw)}],
      "labels":{"role":"node","os":"talos"},"start_after_create":True,"user_data":open(ud).read()}
print(json.dumps(body))
PY
)
  if echo "$resp" | grep -q '"server"'; then
    sid=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['id'])")
    ip=$(echo "$resp" | python3 -c "import json,sys;print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])")
    echo "$(date -Is) SNIPED $name id=$sid ip=$ip ($n/$TARGET)"
    notify ":dart: **Hetzner sniped $TYPE @ $loc** ($n/$TARGET): \`$name\` id \`$sid\`, ip \`$ip\`. Booting into the cluster."
    return 0
  fi
  echo "$(date -Is) grab FAILED @ $loc: $(echo "$resp" | head -c 200)"
  return 1
}

while true; do
  HAVE=$(count)
  if [ "$HAVE" -ge "$TARGET" ]; then
    echo "$(date -Is) $NODE exists, exiting"
    notify ":white_check_mark: **Hetzner sniper done**: $NODE ($TYPE, $LOCS) is up."
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
