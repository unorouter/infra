#!/usr/bin/env bash
# Hetzner budget-node restock watcher (notify-only). Watched: cx33/cx32/cax21 (8GB pref),
# cx22/cax11 (4GB ok) in nbg1-dc3 / hel1-dc2. Loops every 60s; Ctrl+C to stop.
# On hit: prints + desktop notification + ~/.local/state/hetzner-stock-hits.log
set -uo pipefail
source /home/zero/MEGA/Projects/ai-api/infra/tofu/.env

while true; do
HITS=$(python3 - <<EOF
import json,urllib.request,os
tok=os.environ["TF_VAR_hcloud_token"]
def get(u):
    r=urllib.request.Request(u,headers={"Authorization":"Bearer "+tok})
    return json.load(urllib.request.urlopen(r,timeout=20))
types={t['id']:t['name'] for t in get("https://api.hetzner.cloud/v1/server_types?per_page=50")['server_types']}
watch={'cx33','cx32','cax21','cx22','cax11'}
hits=[]
for dc in get("https://api.hetzner.cloud/v1/datacenters")['datacenters']:
    # eu-central only: private network (etcd + DB replication) is zone-bound; nodes must
    # share node1's zone. Covers Falkenstein/Nuremberg/Helsinki -- all 3 usable DCs.
    if dc['location']['network_zone'] != 'eu-central': continue
    avail={types.get(i,'') for i in dc['server_types']['available']}
    hits += [f"{t}@{dc['name']}" for t in sorted(watch & avail)]
print(",".join(hits))
EOF
)

if [ -n "$HITS" ]; then
  echo "$(date -Is) HIT: $HITS"
  echo "$(date -Is) HIT: $HITS" >> /home/zero/.local/state/hetzner-stock-hits.log
  DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
    notify-send -u critical "Hetzner stock!" "$HITS  -- swap manually per DR runbook" 2>/dev/null || true
else
  echo "$(date -Is) no stock (watched: cx33 cx32 cax21 cx22 cax11 in fsn1/nbg1/hel1)"
fi
sleep 60
done
