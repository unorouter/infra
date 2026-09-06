#!/usr/bin/env bash
# Installs the nightly k0s state backup on one controller, by hand from the laptop, over
# Tailscale SSH. S3 keys are read from OpenBao (secret/pg-s3, the same bucket CNPG uses) at
# run time and land only in /etc/k0s-backup/env on the node (root, 0600).
# Usage: install-backup.sh <node-name>
set -euo pipefail
NAME=$1
cd "$(dirname "$0")/../.."
export KUBECONFIG=$PWD/kubeconfig
BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')
ENVTXT=$(printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && bao kv get -format=json secret/pg-s3' | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']['data']
m={'S3_ENDPOINT':d.get('endpoint'),'S3_ACCESS_KEY':d.get('access_key') or d.get('ACCESS_KEY_ID'),'S3_SECRET_KEY':d.get('secret_key') or d.get('SECRET_ACCESS_KEY'),'S3_REGION':d.get('region','eu-central'),'S3_BUCKET':d.get('bucket','unorouter-pg-backups')}
assert all(m.values()), m
print('\n'.join(f'{k}={v}' for k,v in m.items()))")
TSIP=$(tailscale status --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(p['TailscaleIPs'][0] for p in d['Peer'].values() if p['HostName']=='$NAME'))")
scp -q bootstrap/k0s/systemd/k0s-backup.service bootstrap/k0s/systemd/k0s-backup.timer root@"$TSIP":/etc/systemd/system/
ssh root@"$TSIP" 'bash -s' <<EOS
set -e
command -v rclone >/dev/null || (curl -fsSL https://rclone.org/install.sh | bash >/dev/null)
mkdir -p /etc/k0s-backup && umask 077 && cat > /etc/k0s-backup/env <<'ENV'
$ENVTXT
ENV
systemctl daemon-reload && systemctl enable --now k0s-backup.timer && systemctl start k0s-backup.service
systemctl status k0s-backup.service --no-pager | tail -3
EOS
echo ">> verify: rclone lsl on k0s/$NAME/ in the bucket"
