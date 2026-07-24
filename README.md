# infra

Config-as-code for the unorouter revenue stack. 3-node k3s HA on Hetzner (node1 cx33 fsn1 +
node6 cx33 hel1 + node7 cx33 nbg1, embedded etcd, one node per DC = survives a DC outage).
Private net 10.100.0.0/16. Migrated off don + decommissioned 2026-07-23.

Stack: k3s + Cilium (CNI, no kube-proxy) + ArgoCD (app-of-apps) + CloudNativePG (Barman Cloud
plugin -> Hetzner S3 PITR) + OpenBao + ESO + cloudflared tunnel + Teleport + kube-prometheus-stack.
Secrets: SOPS/age in git + OpenBao at runtime. TLS: Cloudflare (tunnel + Origin cert).

Incident history, procedures, break-glass: **`bootstrap/dr/README.md`**.

## DNS (wildcard-only) !PREFER WILDCARD

**Never add a per-host DNS record for an app/ops subdomain.** `*.unorouter.com` CNAME -> the
cloudflared tunnel covers everything. To add a hostname: add a `hostname:` rule to
[cloudflared.yaml](infra/cloudflared/cloudflared.yaml), push, then
`kubectl -n cloudflared rollout restart deploy/cloudflared` (**it reads config only at startup**
- syncing the configmap alone leaves the new host 404ing).

Exceptions that cannot be the wildcard: apex `unorouter.com`, `teleport` (grey-cloud A record,
raw-TLS ALPN passthrough), MX/TXT.

## Ops UIs

- [argocd.unorouter.com](https://argocd.unorouter.com) - GitOps deploy dashboard
- [openbao.unorouter.com](https://openbao.unorouter.com) - secrets vault UI
- [grafana.unorouter.com](https://grafana.unorouter.com) - metrics + alerts

All gated by Teleport SSO (GitHub). Log into
[teleport.unorouter.com](https://teleport.unorouter.com) first, then use the app tiles - a
direct hit 404s without a session by design.

**SSO only, no local passwords anywhere**: Teleport `local_auth: false`, ArgoCD
`admin.enabled: false`, Grafana login form disabled, OpenBao has no userpass method. Grafana
never prompts at all - it reads the `Teleport-Jwt-Assertion` header, so the launcher drops you
straight into the dashboards. Break-glass if GitHub/dex is down: DR runbook.

Hubble has no UI: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe -f`.

## Monitoring

kube-prometheus-stack in `monitoring`, **pinned to node7** (local-path PVCs bind to one node;
swapping node7 = delete those PVCs, lose history, no prod impact). Alerts -> Discord.

Rules (`infra/monitoring/extras/rules-unorouter.yaml`) cover memory/OOM, etcd latency, service
crashloops, backup freshness, CNPG health, public-endpoint probes and disk. Each is derived
from a real incident - the reasoning is in the DR runbook.

- **Routing is drop-by-default.** Root receiver is `null`; only `severity=critical` and
  `warning` reach Discord. Do NOT make `discord` the root receiver - the chart's
  `severity=none` alerts (`Watchdog`, `InfoInhibitor`) then page on every cycle.
- **etcd needs `--etcd-expose-metrics=true`** on every k3s server, else :2381 is
  localhost-only. Targets are a static IP list in `extras/scrape-etcd.yaml` - **update on
  every node swap**.
- **Backup freshness reads the `Backup` CRs** via kube-state-metrics, NOT
  `cnpg_collector_last_available_backup_timestamp` (permanently 0 with the Barman plugin).
- Adding a dex client needs `kubectl -n dex rollout restart deploy/dex` (config read at boot).

## Pinned versions

Bump check: `curl -s https://api.github.com/repos/<org>/<repo>/releases/latest | jq .tag_name`.

| Component | Pinned | Where |
| --- | --- | --- |
| k3s | v1.36.2+k3s1 | node (get.k3s.io stable) |
| hcloud tofu provider | ~> 1.49 | tofu/providers.tf |
| Cilium | 1.19.6 | helm --version |
| Gateway API CRDs | v1.6.1 | applied pre-Cilium |
| cert-manager | v1.21.0 | infra/cert-manager |
| CNPG operator | 1.30.0 | infra/cnpg-operator |
| Barman Cloud plugin | 0.13.0 | infra/cnpg-operator |
| CNPG Postgres | newapi 15, bot 18 (standard-bookworm) | databases/{newapi,bot}-pg |
| OpenBao | chart 0.28.5 (app 2.6.0) | apps/openbao.yaml |
| ArgoCD | 3.4.5 | bootstrap/argocd |
| ESO | 2.8.0 | helm --version |
| cloudflared | 2026.7.0 | apps/cloudflared.yaml |
| Teleport (+ kube-agent) | 18.10.1 | apps/teleport.yaml |
| Velero | 12.1.0 (app 1.18.1) + aws-plugin 1.12.1 | apps/velero.yaml |
| dex | v2.45.1 | cluster OIDC IdP |
| kube-prometheus-stack | 87.19.1 | apps/monitoring.yaml |
| blackbox-exporter | v0.27.0 | infra/monitoring/extras/blackbox.yaml |

## Access (3 tiers, use in order)

**1. Teleport** (primary, audited) - context `teleport.unorouter.com-unorouter`:

```sh
tsh login --proxy=teleport.unorouter.com   # GitHub SSO
tsh kube login unorouter

kubectl -n services logs -l app=new-api --prefix -f --tail 50

# db as the RLS-masked reader (per-session cert, CN=reader):
tsh db connect newapi-pg --db-user=reader --db-name=newapi
# db as admin:
kubectl -n databases exec newapi-pg-1 -c postgres -- psql -U postgres -d newapi -c "<sql>"
```

**2. Direct kubeconfig** (Teleport down) - context `unorouter-direct`, or
`export KUBECONFIG=$PWD/kubeconfig`.

**3. Node SSH** (apiserver down) - `ssh root@<public-ip>` (IPs in `tofu` outputs).

Secrets: `bao kv`.

## tofu

`tofu/.env` (gitignored) exports every `TF_VAR_*`: hcloud_token, s3 keys, k3s_token,
operator_cidr, ssh_public_key, node_type, location.

```sh
cd tofu && tofu init
set -a; source .env; set +a
tofu plan    # READ before apply; server ops one node at a time
tofu apply   # manual only, never CI
```

`tofu apply` is zero-touch: cloud-init writes k3s auto-deploy manifests (Cilium + ArgoCD +
root app-of-apps), so a fresh apply brings the whole stack up from git.

One-time prerequisites: age key `~/.config/sops/age/keys.txt` (**back up offline, loss =
secrets unrecoverable**), Hetzner API token + S3 credentials, Cloudflare
Origin cert.

## Non-negotiable gotchas

- All k3s nodes are SERVERS with `--advertise-address=<private-ip>` (without it remotedialer
  dials public :6443 = firewalled). Cilium `k8sServiceHost: 127.0.0.1` is valid ONLY while
  every node is a server; adding an agent needs that changed first.
- After changing any node's `--node-ip`: restart the cilium DaemonSet (stale cached IPs break
  cross-node vxlan through the firewall).
- CNPG: Barman Cloud PLUGIN (in-tree deprecated 1.26); Hetzner S3 needs the boto3 checksum env
  workaround + path addressing. Test-restore from the REAL bucket is a HARD GATE (cnpg#6645).
- cert-manager ACME blocked by Cilium Opaque-secret pre-creation (cilium#45705) -> CF certs.
- Node ops MANUAL, one node per apply, plan-reviewed (a both-nodes `-replace` caused a 34min
  DB outage; see DR runbook).
- new-api master stays replicas:1 (migration/jobs singleton). CNPG primaries live on node1.
