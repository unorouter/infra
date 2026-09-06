#!/usr/bin/env bash
# Joins one parked spare to the tailnet, by hand, from the operator laptop. Opens SSH on the
# spare for THIS laptop's IP only, installs Tailscale with a key read from OpenBao at run time
# (never written anywhere), then closes the port again. Usage: spare-join.sh <server-name>
set -euo pipefail
NAME=$1
cd "$(dirname "$0")/../.."
set -a; source tofu/.env; set +a
export KUBECONFIG=$PWD/kubeconfig
API=https://api.hetzner.cloud/v1
hc(){ curl -s -H "Authorization: Bearer $TF_VAR_hcloud_token" "$@"; }

MYIP=$(curl -s https://api.ipify.org)
SRV=$(hc "$API/servers?name=$NAME" | python3 -c "import sys,json; s=json.load(sys.stdin)['servers'][0]; print(s['id'], s['public_net']['ipv4']['ip'])")
SID=${SRV% *}; PUB=${SRV#* }
echo ">> $NAME id=$SID ip=$PUB, opening 22 for $MYIP"
FW=$(hc -X POST "$API/firewalls" -H 'Content-Type: application/json' -d "{\"name\":\"bootstrap-$NAME\",\"rules\":[{\"direction\":\"in\",\"protocol\":\"tcp\",\"port\":\"22\",\"source_ips\":[\"$MYIP/32\"]}],\"apply_to\":[{\"type\":\"server\",\"server\":{\"id\":$SID}}]}" | python3 -c "import sys,json; print(json.load(sys.stdin)['firewall']['id'])")
cleanup(){ echo ">> closing 22 (firewall $FW)"; hc -X POST "$API/firewalls/$FW/actions/remove_from_resources" -H 'Content-Type: application/json' -d "{\"remove_from\":[{\"type\":\"server\",\"server\":{\"id\":$SID}}]}" >/dev/null; sleep 3; hc -X DELETE "$API/firewalls/$FW" >/dev/null; }
trap cleanup EXIT
sleep 5

BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')
KEY=$(printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && bao kv get -field=node_auth_key secret/tailscale')
echo ">> installing tailscale on $NAME"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 root@"$PUB" 'bash -s' <<EOS
set -e
hostnamectl set-hostname $NAME
cat > /etc/sysctl.d/90-conntrack.conf <<'S'
net.netfilter.nf_conntrack_max = 262144
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
S
sysctl --system >/dev/null
if ! swapon --show | grep -q swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf && sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
fi
apt-get install -y -qq curl jq >/dev/null
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
tailscale up --auth-key=$KEY --ssh --accept-dns=false --hostname=$NAME
tailscale ip -4
EOS
echo ">> $NAME is on the tailnet; verify with: tailscale status | grep $NAME"
