# infra

Config-as-code for the unorouter revenue stack. 3-node k3s HA on Hetzner (node1 cx33 fsn1 +
node4 cx23 hel1 + node5 cx23 nbg1, embedded etcd, one node per DC = survives a DC outage).
Private net 10.100.0.0/16. Migrated off don + decommissioned 2026-07-23.

Stack: k3s + Cilium (CNI, no kube-proxy) + ArgoCD (app-of-apps) + CloudNativePG (Barman Cloud
plugin -> Hetzner S3 PITR) + OpenBao + ESO + cloudflared tunnel + Teleport. Secrets: SOPS/age
in git + OpenBao at runtime. TLS: Cloudflare (tunnel + Origin cert, no cert-manager ACME).

## DNS (wildcard-only, 2026-07-23) !PREFER WILDCARD

**RULE: always prefer the wildcard. Never add a per-host DNS record for an app/ops subdomain.**
Per-host records are the trap that caused an outage-grade 404 hunt (a hostname rename touched
cloudflared + Teleport but not the manual DNS row). Managing them by hand is banned.

`*.unorouter.com` CNAME -> the k3s cloudflared tunnel (proxied). ALL app + ops hostnames
resolve through it - there are NO per-host DNS records. To add/rename a hostname: add a
`hostname:` rule to [cloudflared.yaml](infra/infra/cloudflared/cloudflared.yaml), commit,
push (ArgoCD syncs). No Cloudflare dashboard, no DNS record. cloudflared's `404` catch-all
handles anything without a rule.

ONLY exceptions that cannot be the wildcard (keep explicit, do not add more): apex
`unorouter.com` (wildcard skips root), `teleport` (grey-cloud A record, raw-TLS ALPN
passthrough - not proxied), `media` (R2 bucket-managed), MX/TXT (email/DKIM). Everything
else is the wildcard - if you find yourself creating a proxied CNAME to the tunnel, stop:
the wildcard already covers it, just add the cloudflared rule.

## Ops UIs (Teleport SSO-gated)

Log into [teleport.unorouter.com](https://teleport.unorouter.com) (GitHub SSO), then the app
tiles. Direct hits 404 without a session by design (Teleport sets the cookie via the launcher).

- [argocd.unorouter.com](https://argocd.unorouter.com) - GitOps deploy dashboard
- [openbao.unorouter.com](https://openbao.unorouter.com) - secrets vault UI

Network flows: no UI (removed 2026-07-23). Use the CLI when debugging:
`kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --follow`.

## Pinned versions

Live-verified 2026-07-23. Bump check: `curl -s https://api.github.com/repos/<org>/<repo>/releases/latest | jq .tag_name`.

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

## Access

```sh
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
kubectl -n databases exec newapi-pg-1 -c postgres -- psql -U postgres -d newapi -c "<sql>"
```

Node SSH: `ssh root@<public-ip>` (IPs in `tofu` outputs). Secrets: `bao kv`. DR: `bootstrap/dr/README.md`.

## One-time prerequisites

1. **age key** `~/.config/sops/age/keys.txt` - BACK UP OFFLINE (loss = secrets unrecoverable).
2. **Hetzner Cloud API token** (rw) + **S3 credentials** (Object Storage, region fsn1, not api-creatable).
3. **Tailscale** reusable authkey (ACL autoApprover for pod CIDR 10.42.0.0/16).
4. **Cloudflare Origin cert** (SSL/TLS -> Origin Server, 15y, `*.unorouter.com`).

## tofu secrets (never plaintext)

```sh
cat > tofu/secrets.sops.yaml <<'EOF'
TF_VAR_hcloud_token: "..."
TF_VAR_s3_access_key: "..."
TF_VAR_s3_secret_key: "..."
TF_VAR_tailscale_authkey: "tskey-auth-..."
TF_VAR_operator_cidr: "x.x.x.x/32"
TF_VAR_k3s_token: "..."   # etcd join token; also in OpenBao secret/cluster
EOF
sops --encrypt --in-place tofu/secrets.sops.yaml
```

`operator_cidr` in sops (public repo). Non-secret vars -> `tofu/terraform.tfvars` (`ssh_public_key`).

## Bootstrap / DR

`tofu apply` is zero-touch: cloud-init writes k3s auto-deploy manifests (Cilium + ArgoCD +
root app-of-apps), so a fresh apply brings up the whole stack from git. Full destroy/restore
procedure (CNPG S3 restore, OpenBao snapshot, lineage bump) + node-swap runbook + the
2026-07-23 incident post-mortems: **`bootstrap/dr/README.md`**.

```sh
cd tofu && tofu init
sops exec-env secrets.sops.yaml 'tofu plan'    # READ before apply; server ops one node at a time
sops exec-env secrets.sops.yaml 'tofu apply'   # manual only, never CI
```

## Non-negotiable gotchas

- All k3s nodes are SERVERS with `--advertise-address=<private-ip>` (without it remotedialer
  dials public :6443 = firewalled). Cilium `k8sServiceHost: 127.0.0.1` is valid ONLY while
  every node is a server; adding an agent needs that changed first.
- After changing any node's `--node-ip`: restart the cilium DaemonSet (agents cache node IPs;
  stale public IP breaks cross-node vxlan through the firewall).
- CNPG: Barman Cloud PLUGIN (in-tree deprecated 1.26); Hetzner-S3 needs the boto3 checksum env
  workaround + path addressing. Test-restore from the REAL bucket is a HARD GATE (cnpg#6645).
- cert-manager ACME blocked by Cilium Opaque-secret pre-creation (cilium#45705) -> CF certs.
- Node ops MANUAL, one node per tofu apply, plan-reviewed (a both-nodes `-replace` caused a
  34min DB outage 2026-07-23; see DR runbook rules).
- new-api master stays replicas:1 (migration/jobs singleton). CNPG primaries live on node1.
