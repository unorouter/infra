#!/usr/bin/env bash
# One script, all DR/ops. Usage: ./scripts/dr.sh <apply|destroy|bootstrap|restore|unseal|kubeconfig>
# Full runbook context: bootstrap/dr/README.md
set -euo pipefail
cd "$(dirname "$0")/.."

NODE_IP() { (cd tofu && tofu output -raw node_ipv4); }
SOPS_KEYS() { sops -d secrets/openbao-init.sops.yaml | grep -oP '^\s*-\s*\K\S+'; }
SOPS_ROOT() { sops -d secrets/openbao-init.sops.yaml | grep -oP '^root_token:\s*\K\S+'; }
export KUBECONFIG="$PWD/kubeconfig"

apply() { (cd tofu && set -a && . ./.env && set +a && tofu apply -auto-approve); }
destroy() { (cd tofu && set -a && . ./.env && set +a && tofu destroy -auto-approve); }
storage_apply() { (cd tofu/storage && set -a && . ../.env && set +a && tofu init && tofu apply -auto-approve); }

kubeconfig() {
  local ip; ip=$(NODE_IP); ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  ssh -o StrictHostKeyChecking=no root@"$ip" 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$ip/" > kubeconfig
  chmod 600 kubeconfig; echo "kubeconfig -> $ip"
}

# Fallback only: cloud-init auto-bootstraps Cilium+ArgoCD. Use if that path fails.
bootstrap() {
  local gw=v1.6.1 cil=1.19.6
  for c in gatewayclasses gateways httproutes referencegrants grpcroutes; do
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw/config/crd/standard/gateway.networking.k8s.io_$c.yaml" >/dev/null
  done
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gw/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml" >/dev/null
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
  echo ">> pull latest snapshot from S3"
  ( cd tofu && set -a && . ./.env && set +a
    RCLONE_CONFIG_HZ_TYPE=s3 RCLONE_CONFIG_HZ_PROVIDER=Ceph RCLONE_CONFIG_HZ_REGION=fsn1 \
    RCLONE_CONFIG_HZ_LOCATION_CONSTRAINT=fsn1 RCLONE_CONFIG_HZ_ENDPOINT=https://fsn1.your-objectstorage.com \
    RCLONE_CONFIG_HZ_ACCESS_KEY_ID="$TF_VAR_s3_access_key" RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY="$TF_VAR_s3_secret_key" \
    rclone copyto hz:unorouter-pg-backups/openbao-snapshots/latest.snap "$snap" )
  echo ">> temp-init to enable restore"
  local tmp; tmp=$(kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=1 -key-threshold=1 -format=json)
  local tkey trt; tkey=$(echo "$tmp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["unseal_keys_b64"][0])')
  trt=$(echo "$tmp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["root_token"])')
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$tkey" >/dev/null
  kubectl -n openbao cp "$snap" openbao-0:/tmp/latest.snap
  echo ">> restore -force"
  kubectl -n openbao exec openbao-0 -- sh -c "BAO_TOKEN='$trt' bao operator raft snapshot restore -force /tmp/latest.snap"
  echo ">> restart pod (raft loads clean only after restart)"
  kubectl -n openbao delete pod openbao-0 >/dev/null; sleep 8
  kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=120s || sleep 15
  unseal
  echo ">> resync ESO (self-healing auth, no reconfigure)"
  kubectl -n external-secrets rollout restart deploy/external-secrets >/dev/null
  echo ">> DONE. Then: tsh login --proxy=teleport.unorouter.com"
}

"${1:?usage: dr.sh <apply|destroy|storage_apply|bootstrap|kubeconfig|unseal|restore>}"
