# Operator entrypoints. Full runbook: bootstrap/dr/README.md
.PHONY: help apply destroy restore vault-unseal vault-snapshot-restore dr-verify bootstrap kubeconfig

KUBECONFIG ?= ./kubeconfig
VAULT_SECRETS ?= secrets/openbao-init.sops.yaml   # SOPS+age: unseal keys + root token
export KUBECONFIG

help:
	@echo "apply                  tofu apply (create/update the node)"
	@echo "destroy                tofu destroy (kill the node; S3+git survive)"
	@echo "restore                DR: unseal Vault (+ raft restore if fresh). Then 'tsh login'."
	@echo "vault-unseal           unseal Vault from SOPS unseal keys"
	@echo "vault-snapshot-restore restore Vault data from the latest S3 raft snapshot"
	@echo "dr-verify              wait for CNPG clusters to report healthy"

apply:
	cd tofu && bash -c 'set -a; . ./.env; set +a; tofu apply'

# the S3 backup bucket lives in its OWN state (tofu/storage) so 'destroy' can't reach it.
# Run once at setup; almost never again. prevent_destroy guards it.
storage-apply:
	cd tofu/storage && bash -c 'set -a; . ../.env; set +a; tofu init && tofu apply'

destroy:
	cd tofu && bash -c 'set -a; . ./.env; set +a; tofu destroy'


# DR: bring secrets back online. CNPG auto-restores via ArgoCD; this handles Vault.
# Teleport = re-login (tsh login), by design (re-login accepted).
restore: dr-verify vault-unseal
	@echo ">> Vault unsealed. If this is a FRESH Vault (empty raft), run: make vault-snapshot-restore"
	@echo ">> Then re-login to Teleport:  tsh login --proxy=teleport.unorouter.com"

vault-unseal:
	@echo ">> unsealing Vault from $(VAULT_SECRETS)"
	@for k in $$(sops -d $(VAULT_SECRETS) | yq -r '.unseal_keys[]'); do \
		kubectl -n openbao exec openbao-0 -- bao operator unseal "$$k"; \
	done
	@kubectl -n openbao exec openbao-0 -- bao status | grep Sealed

# only when the raft store is empty (fresh Vault after full node loss).
# restore Vault data from S3 (only on a FRESH Vault after full node loss). Needs rclone env
# (hz: remote) or set S3 creds. Vault must be initialized+unsealed first, then restore -force.
vault-snapshot-restore:
	@echo ">> pulling latest.snap from S3 into openbao-0 and restoring (raft)"
	rclone copyto hz:unorouter-pg-backups/openbao-snapshots/latest.snap /tmp/vault-latest.snap
	kubectl -n openbao cp /tmp/vault-latest.snap openbao-0:/tmp/latest.snap
	@echo ">> now: kubectl -n openbao exec -it openbao-0 -- sh -c 'BAO_TOKEN=<root> bao operator raft snapshot restore -force /tmp/latest.snap'"
	@echo ">> then RESTART the pod (kubectl -n openbao delete pod openbao-0), then 'make vault-unseal' with ORIGINAL keys"
	@echo ">> (root token: sops -d $(VAULT_SECRETS) | yq -r .root_token)"

dr-verify:
	@echo ">> waiting for CNPG clusters to become healthy"
	kubectl -n databases wait --for=condition=Ready --timeout=600s cluster/newapi-pg
	kubectl -n databases wait --for=condition=Ready --timeout=600s cluster/bot-pg

# --- DR bootstrap: run AFTER 'tofu apply' on a fresh node (Cilium + ArgoCD not in cloud-init) ---
GW_VER ?= v1.6.1
CILIUM_VER ?= 1.19.6
bootstrap: kubeconfig
	@echo ">> Gateway API CRDs"
	@for c in gatewayclasses gateways httproutes referencegrants grpcroutes; do \
		kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GW_VER)/config/crd/standard/gateway.networking.k8s.io_$$c.yaml >/dev/null; done
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GW_VER)/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml >/dev/null
	@echo ">> Cilium"
	helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VER) -n kube-system -f infra/cilium/values.yaml
	kubectl -n kube-system rollout status ds/cilium --timeout=180s
	@echo ">> ArgoCD + root app-of-apps"
	kubectl create namespace argocd 2>/dev/null || true
	kubectl apply -k bootstrap/argocd/ --server-side --force-conflicts
	kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
	kubectl apply -f bootstrap/root-app.yaml
	@echo ">> ArgoCD reconciling from git. Then: make restore (unseal+restore Vault)."

kubeconfig:
	@NODE=$$(cd tofu && tofu output -raw node_ipv4); \
	ssh -o StrictHostKeyChecking=no root@$$NODE 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$$NODE/" > kubeconfig; \
	chmod 600 kubeconfig; echo "kubeconfig -> $$NODE"

# k8s auth is now SELF-HEALING (config uses kubernetes.default.svc + omits token_reviewer_jwt
# -> OpenBao reads its pod SA token/CA fresh each request, survives rebuild). No reconfigure
# target needed anymore. If ever required after a full re-init:
#   kubectl -n openbao exec openbao-0 -- sh -c 'BAO_TOKEN=<root> bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc'
