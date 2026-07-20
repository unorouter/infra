# Operator entrypoints. Full runbook: bootstrap/dr/README.md
.PHONY: help apply destroy restore vault-unseal vault-snapshot-restore dr-verify

KUBECONFIG ?= ./kubeconfig
VAULT_SECRETS ?= secrets/vault-init.enc.yaml   # SOPS+age: unseal keys + root token
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
		kubectl -n vault exec vault-0 -- vault operator unseal "$$k"; \
	done
	@kubectl -n vault exec vault-0 -- vault status | grep Sealed

# only when the raft store is empty (fresh Vault after full node loss).
vault-snapshot-restore:
	@echo ">> fetching latest raft snapshot from S3 and restoring"
	@echo ">> (manual: aws s3 cp s3://unorouter-pg-backups/vault-snapshots/latest.snap . ;"
	@echo ">>  vault operator raft snapshot restore latest.snap) -- see bootstrap/dr/README.md"

dr-verify:
	@echo ">> waiting for CNPG clusters to become healthy"
	kubectl -n databases wait --for=condition=Ready --timeout=600s cluster/newapi-pg
	kubectl -n databases wait --for=condition=Ready --timeout=600s cluster/bot-pg
