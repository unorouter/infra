# Thin index -> scripts/dr.sh. Full runbook: bootstrap/dr/README.md
.PHONY: ips apply destroy storage-apply bootstrap kubeconfig unseal restore
ips apply destroy bootstrap kubeconfig unseal restore:
	@./scripts/dr.sh $@
storage-apply:
	@./scripts/dr.sh storage_apply
