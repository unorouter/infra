# Pinned component versions

All versions verified against upstream releases on **2026-07-21**. Re-check before major
bumps: `curl -s https://api.github.com/repos/<org>/<repo>/releases/latest | jq .tag_name`.
Renovate (P9) automates this later.

| Component | Pinned | Source | Where |
|---|---|---|---|
| k3s | v1.36.2+k3s1 (stable channel) | get.k3s.io | live on node (auto) |
| hcloud tofu provider | ~> 1.66 (1.66.1) | terraform-provider-hcloud | tofu/providers.tf |
| Cilium | 1.19.6 | cilium/cilium | helm install --version |
| Gateway API CRDs | v1.6.1 (standard+tlsroute) | kubernetes-sigs/gateway-api | applied pre-Cilium |
| cert-manager | v1.21.0 | cert-manager/cert-manager | infra/cert-manager |
| CNPG operator | 1.30.0 | cloudnative-pg | infra/cnpg-operator |
| Barman Cloud plugin | 0.13.0 | plugin-barman-cloud | infra/cnpg-operator |
| CNPG PostgreSQL (newapi) | 15-standard-bookworm | ghcr cloudnative-pg/postgresql | databases/newapi-pg |
| CNPG PostgreSQL (bot) | 18-standard-bookworm | ghcr cloudnative-pg/postgresql | databases/bot-pg |
| Vault Helm chart | 0.34.0 | hashicorp/vault-helm | helm install --version |
| Teleport | 18.10.0 | gravitational/teleport | helm install --version |
| ArgoCD | 3.4.5 | argoproj/argo-cd | bootstrap/argocd |
| External Secrets Operator | 2.8.0 (helm-chart) | external-secrets | helm install --version |

Note: earlier scaffolding pinned CNPG 1.27 / barman 0.5 from stale memory; corrected to the
above after live upstream check.
