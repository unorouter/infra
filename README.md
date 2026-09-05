# infra

unorouter revenue stack: 3-node k3s HA on Hetzner (node8 cx43 hel1, node9 cx43 nbg1, node10
cx43 hel1; embedded etcd). Private net 10.100.0.0/16. node6/7/1 swapped out 2026-08-29 to
09-04; `scripts/hetzner-snipe.sh` hunts an fsn1 box to restore the three-DC spread.

Stack: k3s + Cilium (no kube-proxy) + ArgoCD (app-of-apps) + CloudNativePG (Barman plugin ->
Hetzner S3 PITR) + OpenBao + ESO + cloudflared + kube-prometheus-stack. Secrets: SOPS/age in
git, OpenBao at runtime. TLS: everything enters through the Cloudflare tunnel; the only origin
cert that matters is the Teleport proxy's (cert-manager, DNS-01). Edge: Cloudflare Pro, rules
encrypted in this repo. Admin plane: Tailscale for nodes and kubeconfig, Teleport for audited
access; the Hetzner firewall allows NO inbound TCP. Runbook and break-glass:
`bootstrap/dr/README.md`. Post-mortems: `incidents/`.

## Adding a service !SELF-SERVE

**A repo with a `k8s/` directory deploys itself**, no commit here.

1. App repo: `k8s/` with Deployment/Service (`namespace: services`), an ExternalSecret on an
   existing OpenBao key, optionally CNPG `Cluster` + `ObjectStore` + `ScheduledBackup`
   (`namespace: databases`).
2. Push. [apps/appset-services.yaml](apps/appset-services.yaml) scans the org and creates the
   Application within ~15 min (patch the ApplicationSet spec to force a rescan).
3. Push to `main` runs the `GHCR Image` workflow (multi-arch build, then a `deploy(<repo>):
   <sha>` pin commit by `unorouter-ci`; ArgoCD rolls it in 10 to 20 min). Pin commits do not
   retrigger it (`paths-ignore: k8s/deployment.yaml`). Copy the workflow from new-api.

- **Pin images to a git SHA, never `:latest`**: a floating tag changes no manifest, ArgoCD sees
  no diff, nothing deploys.
- **No build secrets in GitHub.** Only `unorouter` needs any (Next.js inlines them): the job
  mints an OIDC JWT (`permissions: id-token: write`) and swaps it at `openbao-ci.unorouter.com`
  for a 10-minute token on one KV path (`ghcr.yml`, step "Fetch build secrets from OpenBao").
  `NEXT_PUBLIC_*` are not secrets and live in a committed `.env.public`. Vault side:
  `./scripts/openbao-ci-auth.sh`.
- `./scripts/build-local.sh <repo> [--deploy]` builds the same artifact locally (amd64, faster
  for hotfixes, coexists with CI, the only path for new-api-sync). A deploy is done when ArgoCD
  shows the new image, never because a push or a workflow succeeded.
- CI reaches OpenBao at `openbao-ci.unorouter.com`, which is exempt from the edge relay-key
  block; if the rule is ever rewritten, keep the exemption (symptom: "Get Vault Secrets" fails
  with a Cloudflare 403 page).
- Generated apps run under the restricted `apps` AppProject
  ([apps/appproject-apps.yaml](apps/appproject-apps.yaml)): `services` + `databases` only, no
  cluster-scoped resources. Shared secrets (`ClusterSecretStore/vault-backend`, `ghcr-pull`,
  pg-s3) stay in this repo.
- **`k8s/` is a deploy gate**: write access to an org repo is write access to the cluster.

## DNS !PREFER WILDCARD

`*.unorouter.com` CNAME -> tunnel covers every host. New hostname: add a `hostname:` rule to
[cloudflared.yaml](infra/cloudflared/cloudflared.yaml), push, then
`kubectl -n cloudflared rollout restart deploy/cloudflared` (config read at startup only).
Only the apex and MX/TXT are separate records; the old grey-cloud `teleport` record exposed a
node IP and is gone.

## Ops UIs

argocd / openbao / grafana.unorouter.com are Teleport App Access: the request lands on the
proxy through the tunnel, the launcher runs GitHub SSO, the agent forwards to the service.
Fallback when Teleport is down:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n openbao port-forward svc/openbao 8200:8200
```

No local passwords: ArgoCD `admin.enabled: "false"` (GitHub through dex, `url` must stay
`https://argocd.unorouter.com` or SSO fails with "Invalid redirect URL"), Grafana login form
off, OpenBao has no userpass. Hubble: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe -f`.

## Monitoring

kube-prometheus-stack in `monitoring`, on node9 (local-path PVC; swapping that node loses
history, no prod impact; a PVC pinned to a dead node stays Pending forever, delete PVC+PV).
Rules: `infra/monitoring/extras/rules-unorouter.yaml` (platform, each from a real incident) and
`rules-security.yaml` (account takeover steps, card chargebacks, guest chat abuse), the latter
fed by SQL over the gateway's audit rows in `cnpg-security-queries.yaml`.

- **Routing is drop-by-default**: root receiver `null`, only critical/warning reach Discord.
  Critical also pages the phone via ntfy (`extras/ntfy-bridge.yaml`, topic URL in OpenBao
  `secret/ntfy`). Test: `amtool alert add` a critical alert in the alertmanager pod.
- **`CloudflaredStreamFlood`** (open tunnel streams far above normal) is the L7 attack signal:
  pages, and fires `edge-mode` (`extras/edge-mode.yaml`), which flips the zone to the attack
  ruleset and back 30 min after resolve.
- CoreDNS is ArgoCD-managed (`infra/coredns/`, 3 replicas, PDB); k3s's bundled manifest is
  disabled by `coredns.yaml.skip` on every server (cloud-init writes it, hand-built nodes need it).
- etcd needs `--etcd-expose-metrics=true` on every server; targets are a static IP list in
  `extras/scrape-etcd.yaml`, update on every node swap.
- Backup freshness reads the `Backup` CRs via kube-state-metrics (the Barman plugin's own
  metric is permanently 0).
- dex clients and blackbox config are read at boot: `rollout restart` the deployment.
- A duplicate group name in `rules-unorouter.yaml` fails the SSA diff and silently stops the
  whole monitoring app syncing; check `.status.conditions` before suspecting drift.
- The monitoring app reads permanently OutOfSync on its ExternalSecrets + `ScrapeConfig/etcd`
  (SSA artifact). Push commits and let auto-sync run; hand-crafted sync operations become
  selective syncs of those 4 resources and skip your manifests (2026-08-12).

## Edge (Cloudflare)

`infra/cloudflare/unorouter.com/`: `rules.sops.yaml` (normal) and `rules.attack.sops.yaml`
(attack), one key per ruleset phase, encrypted because the rule text is the attacker's
playbook. `apply.sh [normal|attack] [phase...]` PUTs each phase with a zone-scoped
`CF_API_TOKEN`. Intent: machine surface (relay paths, PAT calls, preflights, webhooks, MCP)
skips bot management and challenges; browser surfaces are challenged on signal; a per-IP
auto-ban catches single-source floods. Details: `incidents/2026-09-03-l7-ddos.md`.

- Attack mode is automatic (edge-mode); manual `./apply.sh attack` / `normal`.
- A challenge is only ever placed on a page navigation. A fetch, a service worker, a manifest or
  an OAuth start cannot render one, so those paths are either skipped or blocked, never
  challenged (9,345 silent failures in one day before this rule, 2026-09-05).
- Pro until 2027-09. Pro-only pieces in use: Super Bot Fight Mode (skipped for the machine
  surface), the Cloudflare Managed WAF ruleset on browser surfaces, the 1 h auto-ban, Polish.
  Downgrade day: `CF_PLAN=free ./apply.sh` reshapes to 4 custom rules and one 10 s rate limit.
- **After every rule change**: run the allowlist checks in the incident report, then
  `./mitigations.py <hours>`. It lists every non-skip firewall event by rule, host, path, user
  agent and ASN. A webhook sender, CLI client or OPTIONS preflight there is a false positive;
  keyless scanners and empty-UA floods are the expected content.
- Header-name checks must use `lower(http.request.headers.names[*])`: HTTP/1.1 clients keep
  original case.

## Backups

Both to Hetzner S3 `unorouter-pg-backups`:

| What | Mechanism | Retention | Prefix |
| --- | --- | --- | --- |
| Postgres PITR | CNPG + Barman plugin, daily base + WAL | `retentionPolicy: 30d` per ObjectStore | `{newapi,bot}-pg-v4/` |
| PVs + k8s objects | Velero + Kopia, daily 02:00 | `ttl: 336h` | `velero/` |

- `retentionPolicy` unset = nothing ever expires (reached 81 GiB before 2026-08-10).
- `{newapi,bot}-pg-v3/` are live: both clusters bootstrap-restore from them in
  `spec.externalClusters`.
- `kubectl -n velero get backup` resolves to CNPG's CRD and prints nothing. Use
  `get backup.velero.io`.
- Velero's ~69 warnings per run about `*-kopia-maintain-job-*` pods are cosmetic.

## Pinned versions

Bump check: `curl -s https://api.github.com/repos/<org>/<repo>/releases/latest | jq .tag_name`.

| Component | Pinned | Where |
| --- | --- | --- |
| k3s | v1.36.4+k3s1 | node binary swap, one server at a time (tofu var `k3s_version` empty = stable channel) |
| hcloud tofu provider | 1.66.1 (constraint ~> 1.49, lock file) | tofu/providers.tf |
| Cilium | 1.20.1 | live HelmChart CR `cilium` in kube-system + cloud-init template |
| cert-manager | v1.21.1 (+ `letsencrypt-dns` ClusterIssuer, token from OpenBao) | infra/cert-manager |
| CNPG operator | 1.30.0 | infra/cnpg-operator |
| Barman Cloud plugin | 0.15.0 | infra/cnpg-operator |
| CNPG Postgres | newapi 15, bot 18 (standard-bookworm) | databases/{newapi,bot}-pg |
| OpenBao | chart 0.29.4 (app 2.6.2) | apps/openbao.yaml + infra/openbao/values.yaml tag; sts is OnDelete, delete the pod, then unseal (3 of 5 keys, sops) |
| ArgoCD | 3.5.2 (chart 10.7.1) | live HelmChart CR `argo-cd` in kube-system (patch `spec.valuesContent`) + tofu/cloud-init.yaml.tftpl |
| ESO | 2.10.0 | helm --version |
| cloudflared | 2026.8.3 | apps/cloudflared.yaml |
| Teleport (+ kube-agent) | 18.10.1 | apps/teleport.yaml |
| Velero | 12.1.0 (app 1.18.1) + aws-plugin 1.12.1 | apps/velero.yaml |
| dex | v2.45.1 | cluster OIDC IdP |
| kube-prometheus-stack | 88.6.4 (operator CRDs applied server-side first) | apps/monitoring.yaml |
| blackbox-exporter | v0.28.0 | infra/monitoring/extras/blackbox.yaml |

## Access

Everything administrative rides Tailscale (GitHub SSO tailnet; nodes run Tailscale SSH, ACL
allows 22 and 6443 only). Public node IPs accept nothing.

1. **kubeconfig over Tailscale**: `export KUBECONFIG=$PWD/kubeconfig` (server = a node's
   Tailscale IP, `tls-san` in `/etc/rancher/k3s/config.yaml`).
   ```sh
   PG=$(kubectl -n databases get cluster newapi-pg -o jsonpath='{.status.currentPrimary}')
   kubectl -n databases exec $PG -c postgres -- psql -U postgres -d newapi -c "<sql>"
   ```
2. **Node SSH over Tailscale**: `ssh root@<tailscale ip>`, no key.
3. **Tailnet down**: temporary inbound-22 firewall rule for your IP, `./scripts/dr.sh ips`
   (reads IPs from the Hetzner API with only `TF_VAR_hcloud_token`; IPs are not in git), else
   Hetzner VNC console (root password in the password manager) or rescue mode.

### Teleport

Audited access, entirely behind the tunnel: auth and proxy in-cluster (`infra/teleport`), the
app/db/kube agent in `teleport-agent` (`infra/teleport-app-access`). GitHub team -> roles
(`infra/teleport/resources/`): `admins` everything, `readonly` auditor + kube-viewer +
newapi-db-reader, `debuggers` pods in `services` only. Someone outside the org gets the
GitHub authorize page and then nothing: invite them to a team first.

- `tsh login --proxy=teleport.unorouter.com:443 --auth=github` (12 h cert). kubectl cannot talk
  to the proxy through an L7 edge: use `tsh kubectl ...` or `tsh proxy kube
  teleport.unorouter.com` and the kubeconfig it prints. The kube cluster is registered as
  `teleport.unorouter.com`.
- In-cluster clients resolve the proxy to its Service (`infra/coredns/coredns-custom.yaml`), so
  the agent's reverse tunnel never crosses Cloudflare.
- The proxy cert comes from cert-manager (`infra/cert-manager/issuer.yaml`, Secret
  `teleport-origin-tls`). Teleport does not reload it: `rollout restart deploy/teleport-proxy`
  after each renewal.
- The agent keeps its identity in Secret `teleport-app-access-0-state`, not in its volume. After
  an auth rebuild it logs `no authorities for hostname` forever: scale the sts to 0, delete
  that Secret, scale to 1.

Org hardening that must stay regardless: base repo permission `none`, member repo creation
OFF (the ApplicationSet deploys any org repo with `k8s/`), contributions via fork PRs.

### Node disk

Images are the only reclaimable chunk; the rest of the 75G root is live local-path data.
Kubelet `image-gc-high-threshold=70` / `low=55` is set in `tofu/cloud-init*.tftpl` AND
`/etc/rancher/k3s/config.yaml` on each node (keep in sync; `systemctl restart k3s` one node at
a time). Manual prune:

```sh
/var/lib/rancher/k3s/data/current/bin/crictl -r unix:///run/k3s/containerd/containerd.sock rmi --prune
```

`NodeDiskFillingUp` at 75% means GC already ran and the growth is real data.

## tofu

`tofu/.env` (gitignored) exports every `TF_VAR_*`.

```sh
cd tofu && tofu init
set -a; source .env; set +a
tofu plan    # read before apply; server ops one node at a time
tofu apply   # manual only
```

Zero-touch: cloud-init writes k3s auto-deploy manifests (Cilium + ArgoCD + root app), so a
fresh apply brings the stack up from git. Prerequisites: age key `~/.config/sops/age/keys.txt`
(back up offline, loss = secrets unrecoverable), Hetzner token + S3 keys, Cloudflare Origin cert.

## Non-negotiable gotchas

- All nodes are k3s SERVERS with `--advertise-address=<private-ip>`. Cilium
  `k8sServiceHost: 127.0.0.1` is valid only while that holds; an agent node needs it changed.
- After changing a `--node-ip`: restart the cilium DaemonSet.
- CNPG uses the Barman Cloud PLUGIN; Hetzner S3 needs the boto3 checksum workaround + path
  addressing. Test-restore from the real bucket is a hard gate (cnpg#6645).
- ACME HTTP-01 can never reach an origin behind the tunnel: issue with the `letsencrypt-dns`
  ClusterIssuer (DNS-01 through the Cloudflare token) or use Cloudflare's own certs.
- Node ops manual, one node per apply, plan reviewed (a both-nodes `-replace` = 34 min DB
  outage, DR runbook).
- new-api master stays replicas:1. CNPG primaries drift on failover: read
  `status.currentPrimary` every time.
- **The Cilium and ArgoCD HelmChart CRs exist only in the cluster.** node1, the cluster-init
  node that carried their bootstrap files, is gone and node10 has none. Upgrade by patching
  the live CR (`spec.valuesContent`) AND `tofu/cloud-init.yaml.tftpl`, which is the DR copy.
  Both carry `failurePolicy: abort` and ArgoCD keeps its CRDs, because on 2026-09-03 a
  re-applied bootstrap file with the default `reinstall` policy uninstalled ArgoCD and every
  Application vanished (workloads survived, restored from `root-app.yaml` + git). If a future
  cluster-init node gets bootstrap files again, they become authoritative on every k3s restart.
- Firewall (`tofu/firewall.tf`) allows Tailscale UDP + ICMP only. Never open 22/6443 without a
  source IP and a removal step.
