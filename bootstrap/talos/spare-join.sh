#!/usr/bin/env bash
# Turns a parked Hetzner spare into a cluster node, from the operator laptop, with nothing on
# the node to prepare: rename it, rebuild it to the Talos snapshot (keeps the server, its IPs
# and the stock slot; user data is create only), let it boot into maintenance mode, then send
# the rendered machine config over the maintenance API. That API is unauthenticated by design,
# so it is opened for THIS laptop's IP only (tcp/50000) and closed again by the exit trap.
# The node reboots into the config, installs to disk, joins the tailnet with the pre-signed key
# in the config and joins the cluster. Usage: spare-join.sh <server-name> <node-name>
#   spare-join.sh unorouter-spare-nbg1-3 unorouter-node13
set -euo pipefail
SERVER=$1; NODE=$2
cd "$(dirname "$0")"
CFG="clusterconfig/unorouter-$NODE.yaml"
[ -f "$CFG" ] || { echo "!! $CFG missing: talhelper genconfig first" >&2; exit 1; }
SIZE=$(wc -c < "$CFG"); [ "$SIZE" -le 32768 ] || { echo "!! $CFG is $SIZE bytes, Hetzner user data caps at 32768" >&2; exit 1; }
set -a; source ../../tofu/.env; set +a
API=https://api.hetzner.cloud/v1
hc(){ curl -sf -H "Authorization: Bearer $TF_VAR_hcloud_token" "$@"; }
j(){ python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

SRV=$(hc "$API/servers?name=$SERVER" | j "str(d['servers'][0]['id']) + ' ' + d['servers'][0]['public_net']['ipv4']['ip']")
SID=${SRV% *}; PUB=${SRV#* }
IMAGE=$(hc "$API/images?type=snapshot&label_selector=os=talos&sort=created:desc" | j "d['images'][0]['id']")
echo ">> $SERVER id=$SID ip=$PUB -> $NODE, image $IMAGE"

hc -X PUT "$API/servers/$SID" -H 'Content-Type: application/json' -d "{\"name\":\"$NODE\",\"labels\":{\"os\":\"talos\"}}" >/dev/null
ACT=$(hc -X POST "$API/servers/$SID/actions/rebuild" -H 'Content-Type: application/json' -d "{\"image\":\"$IMAGE\"}" | j "d['action']['id']")
until [ "$(hc "$API/actions/$ACT" | j "d['action']['status']")" = success ]; do sleep 5; done
echo ">> rebuilt, waiting for the maintenance API"

MYIP=$(curl -s https://api.ipify.org)
FW=$(hc -X POST "$API/firewalls" -H 'Content-Type: application/json' -d "{\"name\":\"bootstrap-$NODE\",\"rules\":[{\"direction\":\"in\",\"protocol\":\"tcp\",\"port\":\"50000\",\"source_ips\":[\"$MYIP/32\"]}],\"apply_to\":[{\"type\":\"server\",\"server\":{\"id\":$SID}}]}" | j "d['firewall']['id']")
cleanup(){ echo ">> closing 50000 (firewall $FW)"; hc -X POST "$API/firewalls/$FW/actions/remove_from_resources" -H 'Content-Type: application/json' -d "{\"remove_from\":[{\"type\":\"server\",\"server\":{\"id\":$SID}}]}" >/dev/null || true; sleep 3; hc -X DELETE "$API/firewalls/$FW" >/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 60); do talosctl --insecure -n "$PUB" version --client=false >/dev/null 2>&1 && break; sleep 5; done
talosctl apply-config --insecure -n "$PUB" -f "$CFG"
echo ">> config applied, $NODE installs and reboots. Then: tailscale status | grep $NODE; talosctl -n $NODE.taild195fa.ts.net health"
