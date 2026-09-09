#!/usr/bin/env bash
# One script, all DR/ops. The cert kubeconfig (kubeconfig.breakglass) is NOT kept on disk:
# run `dr.sh kubeconfig` first to fetch it from a node over SSH, shred it when done; every
# request with it pages (system:admin), day-to-day kubectl goes through Teleport.
# Usage: ./scripts/dr.sh <ips|apply|destroy|bootstrap|restore|unseal|kubeconfig|root>
# Full runbook context: bootstrap/dr/README.md
set -euo pipefail
cd "$(dirname "$0")/.."

# Node IPs are deliberately NOT in git (public repo). Source of truth is the Hetzner API,
# which needs only the token -- no tofu init, no S3 state, no working cluster. That matters:
# every consumer of this is a break-glass path where those may all be unavailable.
ips() {
  set -a && . ./tofu/.env && set +a
  curl -sf -H "Authorization: Bearer $TF_VAR_hcloud_token" 'https://api.hetzner.cloud/v1/servers' \
    | python3 -c "
import sys,json
for s in json.load(sys.stdin).get('servers',[]):
    dc=(s.get('datacenter') or {}).get('name') or (s.get('location') or {}).get('name') or '?'
    print('%-22s %-16s %-10s %s' % (s['name'], s['public_net']['ipv4']['ip'], dc, s['status']))
"
}

# single node's IP by name, for scripting: NODE_IP unorouter-node8
NODE_IP() {
  local want="${1:-unorouter-node8}"
  set -a && . ./tofu/.env && set +a
  curl -sf -H "Authorization: Bearer $TF_VAR_hcloud_token" "https://api.hetzner.cloud/v1/servers?name=$want" \
    | python3 -c "
import sys,json
s=json.load(sys.stdin).get('servers') or sys.exit('no server named $want')
print(s[0]['public_net']['ipv4']['ip'])
"
}
# awk scopes the match to the unseal_keys block; a bare list-grep would swallow any other
# YAML list ever added to the file and feed garbage into `bao operator unseal`.
SOPS_KEYS() { sops -d secrets/openbao-init.sops.yaml | awk '/^unseal_keys:/{f=1;next} /^[^ ]/{f=0} f' | grep -oP '^\s*-\s*\K\S+'; }
# No standing root token exists (revoked 2026-09-08): `dr.sh root` mints one from three unseal
# keys for a DR session; revoke it again with `bao token revoke <token>` when done. Every request
# with it pages OpenBaoRootUsed, and that is intended.
# OpenBao >= 2.6 serves root generation ONLY on the authenticated sys/generate-root-token
# endpoints (the unauthenticated sys/generate-root ones are off by default since 2.5,
# CVE-2026-5807). So this needs a token with sudo on sys/* in the pod's environment: log in
# as OIDC admin first and pass it as BAO_TOKEN. With NO working auth method at all (2026-09-08
# 05:20 CEST lockout), the only way in was the R2 raft snapshot: `dr.sh restore`.
generate_root() {
  echo ">> generate-root from unseal keys"
  local init nonce otp enc
  init=$(kubectl -n openbao exec openbao-0 -- bao operator generate-root -init -format=json)
  nonce=$(echo "$init" | python3 -c 'import sys,json;print(json.load(sys.stdin)["nonce"])')
  otp=$(echo "$init" | python3 -c 'import sys,json;print(json.load(sys.stdin)["otp"])')
  local n=0
  while IFS= read -r k && [ "$n" -lt 3 ]; do
    enc=$(kubectl -n openbao exec openbao-0 -- bao operator generate-root -nonce="$nonce" -format=json "$k" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("encoded_token",""))')
    n=$((n+1))
  done < <(SOPS_KEYS)
  [ -n "$enc" ] || { echo "!! generate-root did not complete" >&2; exit 1; }
  kubectl -n openbao exec openbao-0 -- bao operator generate-root -decode="$enc" -otp="$otp"
}
export KUBECONFIG="$PWD/kubeconfig.breakglass"

# No -auto-approve: lesson 1 of INCIDENT 2026-07-23 (a blind apply -replace'd both nodes,
# 34min DB outage). tofu prompts; read the plan.
apply() { (cd tofu && set -a && . ./.env && set +a && tofu init -input=false >/dev/null && tofu apply); }
destroy() { (cd tofu && set -a && . ./.env && set +a && tofu init -input=false >/dev/null && tofu destroy); }
storage_apply() { (cd tofu/storage && set -a && . ../.env && set +a && tofu init -input=false >/dev/null && tofu apply); }

# Nodes have no public SSH (Hetzner firewall: Tailscale UDP 41641 and ICMP only) and no
# authorized_keys: root comes only through Tailscale SSH (2-don identity, 12h check, lock).
# The kubeconfig points at the node's tailnet address; the Hetzner console is the last resort.
TS_IP() { tailscale status --json | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in list(d['Peer'].values())+[d['Self']]:
    if p['HostName']=='$1': print(p['TailscaleIPs'][0]); break
"; }
kubeconfig() {
  local ip; ip=$(TS_IP "${1:-unorouter-node8}"); [ -n "$ip" ] || { echo "!! node not on the tailnet" >&2; exit 1; }
  ssh -o StrictHostKeyChecking=accept-new root@"$ip" 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$ip/" > kubeconfig.breakglass
  chmod 600 kubeconfig.breakglass; echo "kubeconfig.breakglass -> $ip (shred -u it when done)"
}

# Read one OpenBao KV field with no Teleport and no operator token: ESO's kubernetes-auth
# role (policy eso-read, secret/*) is exchanged inside the pod for a short token, the value
# comes back on stdout and nothing touches disk. Needs kubeconfig.breakglass (an exec is
# audited as system:admin and pages K8sPodExec, which is the point). Port-forwarding to
# OpenBao is dropped by its network policy, exec is the only in-cluster path.
bao_read() {
  local path="${1:?secret path, e.g. teleport-github}" field="${2:?field}"
  local sat; sat=$(kubectl -n external-secrets create token external-secrets --duration=10m)
  printf '%s\n' "$sat" | kubectl -n openbao exec -i openbao-0 -- sh -c '
    read -r J; export BAO_ADDR=http://127.0.0.1:8200
    T=$(printf "%s" "$J" | bao write -field=token auth/kubernetes/login role=eso jwt=-) || exit 1
    BAO_TOKEN="$T" bao kv get -field='"$field"' secret/'"$path"'; rc=$?
    BAO_TOKEN="$T" bao token revoke -self >/dev/null 2>&1; exit $rc'
}

# Fallback only: cloud-init auto-bootstraps Cilium+ArgoCD. Use if that path fails.
bootstrap() {
  local cil=1.19.6
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm upgrade --install cilium cilium/cilium --version "$cil" -n kube-system -f infra/cilium/values.yaml
  kubectl -n kube-system rollout status ds/cilium --timeout=180s
  kubectl create namespace argocd 2>/dev/null || true
  kubectl apply -k bootstrap/argocd/ --server-side --force-conflicts
  kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
  kubectl apply -f bootstrap/root-app.yaml
  echo ">> ArgoCD reconciling from git. Next: ./scripts/dr.sh restore"
}

unseal() {
  echo ">> unsealing OpenBao"
  while IFS= read -r k; do kubectl -n openbao exec openbao-0 -- bao operator unseal "$k" >/dev/null; done < <(SOPS_KEYS)
  kubectl -n openbao exec openbao-0 -- bao status | grep Sealed
}

# FULL auto DR restore of a fresh OpenBao: temp-init -> restore snapshot -> restart -> unseal.
restore() {
  local snap=/tmp/openbao-latest.snap
  # Hetzner Object Storage, SSE-C. OpenBao does not exist yet at this point, so the credential
  # comes from tofu/.env (the same Hetzner project key) and the SSE-C key from the break-glass
  # SOPS file, never from a live Secret.
  echo ">> pull latest snapshot from Hetzner (tofu/.env credential, SSE-C key from secrets/backup-encryption.sops.yaml)"
  local ak sk kb km
  ak=$(grep -E '^export AWS_ACCESS_KEY_ID=' tofu/.env | cut -d= -f2-); sk=$(grep -E '^export AWS_SECRET_ACCESS_KEY=' tofu/.env | cut -d= -f2-)
  kb=$(sops -d --extract '["stringData"]["sse_c_key_b64"]' secrets/backup-encryption.sops.yaml)
  km=$(sops -d --extract '["stringData"]["sse_c_key_md5_b64"]' secrets/backup-encryption.sops.yaml)
  [ -n "$ak" ] && [ -n "$kb" ] || { echo "!! need tofu/.env AWS_* and the break-glass age key for secrets/backup-encryption.sops.yaml" >&2; exit 1; }
  RCLONE_CONFIG_HZ_TYPE=s3 RCLONE_CONFIG_HZ_PROVIDER=Ceph RCLONE_CONFIG_HZ_NO_CHECK_BUCKET=true RCLONE_CONFIG_HZ_REGION=fsn1 \
  RCLONE_CONFIG_HZ_ENDPOINT=https://fsn1.your-objectstorage.com \
  RCLONE_CONFIG_HZ_ACCESS_KEY_ID="$ak" RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY="$sk" \
  RCLONE_CONFIG_HZ_SSE_CUSTOMER_ALGORITHM=AES256 RCLONE_CONFIG_HZ_SSE_CUSTOMER_KEY_BASE64="$kb" RCLONE_CONFIG_HZ_SSE_CUSTOMER_KEY_MD5="$km" \
  rclone copyto "hz:unorouter-backups/openbao-snapshots/latest.snap" "$snap"
  gzip -t "$snap" || { echo "!! $snap is not a valid gzip snapshot" >&2; exit 1; }
  # a truncated/error-body snapshot restored with -force would destroy the vault; real
  # snapshots run ~90KB, an OpenBao JSON error is <1KB
  local size; size=$(stat -c%s "$snap")
  [ "$size" -gt 10240 ] || { echo "!! $snap is only $size bytes -- refusing to restore. Pull a timestamped snapshot from openbao-snapshots/ instead." >&2; exit 1; }
  echo ">> temp-init to enable restore"
  local tmp; tmp=$(kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=1 -key-threshold=1 -format=json)
  local tkey trt; tkey=$(echo "$tmp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["unseal_keys_b64"][0])')
  trt=$(echo "$tmp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["root_token"])')
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$tkey" >/dev/null
  # Not kubectl cp / exec -i: a 450 KB stdin over the API broke mid-stream on 2026-09-08 and the
  # restore then failed on an empty file. Stage it on the node into the pod's own PV directory.
  local pvdir; pvdir=$(ssh root@"$(TS_IP "$(kubectl -n openbao get pod openbao-0 -o jsonpath='{.spec.nodeName}')")" 'ls -d /var/lib/rancher/k3s/storage/*_openbao_data-openbao-0' | head -1)
  scp "$snap" root@"$(TS_IP "$(kubectl -n openbao get pod openbao-0 -o jsonpath='{.spec.nodeName}')")":"$pvdir/latest.snap"
  echo ">> restore -force"
  # token via stdin, not argv: exec args land in the apiserver audit log + pod process table
  printf '%s\n' "$trt" | kubectl -n openbao exec -i openbao-0 -- \
    sh -c 'read -r BAO_TOKEN && export BAO_TOKEN && bao operator raft snapshot restore -force /openbao/data/latest.snap && rm -f /openbao/data/latest.snap'
  echo ">> restart pod (raft loads clean only after restart)"
  kubectl -n openbao delete pod openbao-0 --wait=true >/dev/null
  # wait for the StatefulSet to recreate the pod object before `kubectl wait` can watch it
  for _ in $(seq 30); do kubectl -n openbao get pod openbao-0 >/dev/null 2>&1 && break; sleep 2; done
  kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=180s
  unseal
  echo ">> resync ESO (self-healing auth, no reconfigure)"
  kubectl -n external-secrets rollout restart deploy/external-secrets >/dev/null
  echo ">> DONE. Then: tsh login --proxy=teleport.unorouter.com"
}

cmd="${1:?usage: dr.sh <ips|apply|destroy|storage_apply|bootstrap|kubeconfig|unseal|restore|root>}"
shift
root() { generate_root; }
bao-read() { bao_read "$@"; }
"$cmd" "$@"
