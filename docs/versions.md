# Pinned versions

Bump check: `curl -s https://api.github.com/repos/<org>/<repo>/releases/latest | jq .tag_name`.

| Component | Pinned | Where |
| --- | --- | --- |
| k3s | v1.36.4+k3s1 | node binary swap, one server at a time |
| hcloud tofu provider | 1.66.1 | tofu/providers.tf |
| Cilium | 1.20.1 | live HelmChart CR `cilium` in kube-system + cloud-init |
| cert-manager | v1.21.1 | infra/cert-manager |
| CNPG operator / Barman plugin | 1.30.0 / 0.15.0 | infra/cnpg-operator |
| CNPG Postgres | newapi 15, bot 18 | databases/{newapi,bot}-pg |
| OpenBao | chart 0.29.4 (app 2.6.2) | apps/openbao.yaml; sts is OnDelete, delete the pod then unseal (3 of 5) |
| ArgoCD | 3.5.2 (chart 10.7.1) | live HelmChart CR `argo-cd` in kube-system + cloud-init |
| ESO | 2.10.0 | helm --version |
| cloudflared | 2026.8.3 | apps/cloudflared.yaml |
| Teleport (+ kube-agent) | 18.10.1 | apps/teleport.yaml |
| Velero | 12.1.0 + aws-plugin 1.12.1 | apps/velero.yaml |
| dex | v2.45.1 | cluster OIDC IdP |
| kube-prometheus-stack | 88.6.4 | apps/monitoring.yaml |
| blackbox-exporter | v0.28.0 | infra/monitoring/extras/blackbox.yaml |
