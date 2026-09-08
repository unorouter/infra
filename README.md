# infra

unorouter revenue stack: 3-node k3s HA on Hetzner (node8 hel1, node9 nbg1, node10 hel1, cx43,
embedded etcd, private net 10.100.0.0/16). k3s + Cilium (no kube-proxy) + ArgoCD (app-of-apps) +
CloudNativePG (Barman plugin, PITR to R2) + OpenBao + ESO + cloudflared + kube-prometheus-stack.

Everything enters through the Cloudflare tunnel; the Hetzner firewall allows only Tailscale UDP
and ICMP. Runbook and break-glass: [bootstrap/dr/README.md](bootstrap/dr/README.md).
Post-mortems: [incidents/](incidents/).

## Access

Daily work is a named, expiring session. Nothing standing lives on a laptop.

| Need | How | Expires |
| --- | --- | --- |
| kubectl | `KUBECONFIG=~/.kube/teleport-unorouter.yaml` (systemd user unit `tsh-kube` runs `tsh proxy kube --port 18443 unorouter`) | 12 h cert |
| Postgres | `tsh db login newapi-pg --db-user dbadmin\|reader --db-name newapi`, then `tsh db connect newapi-pg` | 12 h cert |
| OpenBao | `BAO_ADDR=http://127.0.0.1:18200` (unit `tsh-openbao`), `bao login -method=oidc role=admin` | 7 d token |
| Node shell | `ssh root@<tailscale ip>` (Tailscale SSH, no key) | identity check every 12 h |
| Ops UIs | argocd / openbao / grafana.unorouter.com through Teleport App Access, GitHub SSO | 12 h |

Re-login: `tsh login --proxy=teleport.unorouter.com:443 --auth=github --browser=none`, open the
printed URL, then `systemctl --user restart tsh-kube tsh-openbao`.

**Break-glass** (Teleport, GitHub or Dex down). Each path is account-free and pages on use:

- Cluster: `./scripts/dr.sh kubeconfig [node]` pulls `/etc/rancher/k3s/k3s.yaml` over Tailscale
  into `kubeconfig.breakglass`. It authenticates as `system:admin`, so every request fires
  `K8sSecretRead` / `K8sPodExec`. `shred -u` it when done.
- OpenBao: `./scripts/dr.sh root` runs `generate-root` with three unseal keys. Fires
  `OpenBaoRootUsed`. `bao token revoke` it when done.
- No Tailscale: Hetzner console for the nodes, netcup SCP console for the VPS boxes.
- Offline (VeraCrypt volume plus Bitwarden): unseal keys, tailnet lock disablement secrets,
  break-glass sops age key, the Hetzner operator SSH key. Nothing of this is in OpenBao, so a
  sealed or destroyed vault stays recoverable.

**sops has two keys**: the daily one lives in OpenBao `secret/sops-age` and opens the Cloudflare
edge rules (`. scripts/sops-env.sh`, or `apply.sh` fetches it itself); the break-glass one is
offline only and is the sole recipient of `secrets/openbao-init.sops.yaml` (unseal keys) and
`secrets/tailnet-lock.sops.yaml`.

**Tailnet** `2-don.github` (a different GitHub account than the org's `0-don`, on purpose):
Tailnet Lock on, so a device added by a hijacked login is inert until signed from this laptop or
netcup; manual device approval; ACL in [infra/tailscale/acl.hujson](infra/tailscale/acl.hujson)
grants only the operator and the `node`/`ops` tags, SSH is `action: check` with `checkPeriod:
12h`. No host has an `authorized_keys` entry.

### Teleport

Auth and proxy in-cluster ([infra/teleport](infra/teleport)), the app/db/kube agent in
`teleport-agent` ([infra/teleport-app-access](infra/teleport-app-access)). GitHub team to roles
in `infra/teleport/resources/`: `admins` everything plus `newapi-db-admin`, `readonly` auditor +
kube-viewer + newapi-db-reader, `debuggers` pods in `services` only. Someone outside the org
gets the authorize page and then nothing.

- Audit shows the agent SA with `impersonatedUser: <github login>`; every `kubectl exec` is a
  recorded session. `tctl` works locally: `~/.local/bin/tctl --auth-server=teleport.unorouter.com:443`.
- `tctl get github/github` OMITS `client_secret`; re-applying its output wipes SSO
  (`incorrect_client_credentials`). Rebuild from `resources/github-connector.yaml` plus OpenBao
  `secret/teleport-github`. The auth container is distroless, so use local `tctl`.
- Role changes land in the cert: `tsh logout && tsh login` before they take effect.
- DB access needs the Teleport db-client CA inside CNPG's `clientCASecret` bundle (OpenBao
  `secret/newapi-pg-client-ca`, own CA first, `ca.key` kept). Refresh it after any auth rebuild,
  symptom `FATAL: connection requires a valid client certificate`.
- The proxy cert comes from cert-manager; Teleport does not reload it, `rollout restart
  deploy/teleport-proxy` after renewal. The agent's identity is Secret
  `teleport-app-access-0-state`: after an auth rebuild, scale to 0, delete it, scale to 1.

## Adding a service !SELF-SERVE

**A repo with a `k8s/` directory deploys itself**, no commit here.

1. App repo: `k8s/` with Deployment/Service (`namespace: services`), an ExternalSecret on an
   existing OpenBao key, optionally CNPG `Cluster` + `ObjectStore` + `ScheduledBackup`
   (`namespace: databases`), and a `CiliumNetworkPolicy` in `infra/services/networkpolicies.yaml`
   here, because that namespace is default-deny.
2. Push. [apps/appset-services.yaml](apps/appset-services.yaml) scans the org and creates the
   Application within ~15 min.
3. Push to `main` runs the `GHCR Image` workflow (multi-arch build, then a `deploy(<repo>):
   <sha>` pin commit by `unorouter-ci`; ArgoCD rolls it in 10 to 20 min). Copy the workflow from
   new-api and keep `paths-ignore` on `k8s/**` and `**.md` so pins and docs do not rebuild.

- **Pin images to a git SHA, never `:latest`**: a floating tag changes no manifest, ArgoCD sees
  no diff, nothing deploys.
- **No build secrets in GitHub.** Only `unorouter` needs any (Next.js inlines them): the job
  mints an OIDC JWT and swaps it at `openbao-ci.unorouter.com` for a 10-minute token on one KV
  path. `NEXT_PUBLIC_*` live in a committed `.env.public`. Vault side:
  `./scripts/openbao-ci-auth.sh`. Keep that host exempt from the edge relay-key block.
- `./scripts/build-local.sh <repo> [--deploy]` builds the same artifact locally (amd64, the only
  path for new-api-sync). A deploy is done when ArgoCD shows the new image, never because a push
  or a workflow succeeded.
- Generated apps run under the restricted `apps` AppProject: `services` + `databases` only, no
  cluster-scoped resources.
- **`k8s/` is a deploy gate**: write access to an org repo is write access to the cluster.

## Pod isolation

All 13 namespaces are default-deny (plain `NetworkPolicy`, empty selector, Ingress+Egress) plus
one `CiliumNetworkPolicy` per workload in `infra/<ns>/networkpolicies.yaml`. A pod reaches only
its own dependencies, and the internet only on the ports its code can dial.

- **Never `toFQDNs` or a DNS L7 rule here**: with socket-LB + vxlan + legacy host routing the
  transparent DNS proxy drops every redirected query (cilium/cilium#46284). Internet egress is
  `toCIDR` where documented, else `toEntities: [world]` on named ports.
- Ports in rules are container ports. The API server is `[host, remote-node, kube-apiserver]`
  (admission webhooks arrive from those). Kubelet probes arrive as `host`.
- Stage with `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled` on every endpoint of the
  namespace BEFORE the policy lands, watch `hubble observe --verdict AUDIT --verdict DROPPED`,
  then disable audit and watch drops again.
- Helm/ArgoCD hook Jobs run under their own ServiceAccount and are enforced from birth: put them
  in a selector first or the sync wedges with the Job stuck on `hook-finalizer`.
- **Run a cluster-wide `hubble observe --verdict DROPPED --since 60m` an hour after any policy
  change.** Clients that only talk on user action (Grafana verifying a JWT, a watcher paging
  Alertmanager) never show up in a quiet 10-minute window; both broke silently that way.

## Monitoring

kube-prometheus-stack in `monitoring` (local-path PVCs; a PVC pinned to a dead node stays Pending
forever, delete PVC+PV). Rules: `extras/rules-unorouter.yaml` (platform, each from a real
incident) and `rules-security.yaml` (account takeover, chargebacks, guest abuse), the latter fed
by SQL over the gateway's audit rows in `cnpg-security-queries.yaml`.

- **Watchers** (`extras/*-watch.yaml`, CronJobs every 5 min plus the `k8s-audit-watch` DaemonSet)
  post to Discord and page on exceptions: non-routine Secret reads and any `exec`
  (`K8sSecretRead`, `K8sPodExec`), OpenBao root use (`OpenBaoRootUsed`), Teleport role/connector/
  user changes (`TeleportPrivilegeChange`), pgaudit rows from a non-app role, Cloudflare account
  audit, GHCR visibility, image-layer secret scans, SSO logins. Named Teleport operators
  (`NAMED_USERS`) go into one daily digest instead, since Teleport records their sessions.
  A new platform component that reads Secrets belongs in `ROUTINE_USERS`, not in silence.
- **Routing is drop-by-default**: root receiver `null`, only critical/warning reach Discord;
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **`CloudflaredStreamFlood`** is the L7 attack signal: pages, and fires `edge-mode`, which flips
  the zone to the attack ruleset and back 30 min after resolve.
- etcd needs `--etcd-expose-metrics=true` on every server; targets are a static IP list in
  `extras/scrape-etcd.yaml`, update on every node swap.
- Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients and blackbox config are read at boot: `rollout restart` the deployment.
- A duplicate group name in `rules-unorouter.yaml` fails the SSA diff and silently stops the whole
  monitoring app syncing; check `.status.conditions` before suspecting drift.
- Prometheus, Alertmanager, Grafana, blackbox and kps-operator are still pinned to node9 by
  `nodeSelector`; that node is the single point of failure for monitoring.

## Edge (Cloudflare)

`infra/cloudflare/unorouter.com/`: `rules.sops.yaml` (normal), `rules.attack.sops.yaml` (attack),
one key per ruleset phase, encrypted because the rule text is the attacker's playbook.
`apply.sh [normal|attack] [phase...]` PUTs each phase with a zone-scoped `CF_API_TOKEN` and
fetches the daily sops key from OpenBao itself. Intent: machine surface (relay paths, PAT calls,
preflights, webhooks, MCP) skips bot management; browser surfaces are challenged on signal; a
per-IP auto-ban catches single-source floods. Details: `incidents/2026-09-03-l7-ddos.md`.

- A challenge only renders on a page navigation. A fetch, service worker, manifest or OAuth start
  cannot, so those paths are skipped or blocked, never challenged (9,345 silent failures in one
  day before this rule).
- Pro until 2027-09. Downgrade day: `CF_PLAN=free ./apply.sh`.
- **After every rule change**: allowlist checks from the incident report, then `./mitigations.py
  <hours>`. A webhook sender, CLI client or OPTIONS preflight in that list is a false positive.
- Header-name checks must use `lower(http.request.headers.names[*])`.
- 504s with origin status 0 and UA "…early hints" are Cloudflare synthetics, filter them out
  before reading any 5xx rate.

## Backups

All to Cloudflare R2 `unorouter-backups` (Hetzner S3 holds only the tofu state).

| What | Mechanism | Retention | Prefix |
| --- | --- | --- | --- |
| Postgres PITR | CNPG + Barman plugin, daily base + WAL | 30d per ObjectStore | `{newapi,bot}-pg-v5/` |
| PVs + k8s objects | Velero + Kopia, daily 02:00 | `ttl: 336h` | `velero/` |
| OpenBao raft | CronJob snapshot | bucket lifecycle | `openbao-snapshots/` |
| Teleport recordings | `audit_sessions_uri` | bucket lifecycle | `teleport-recordings/` |

- `retentionPolicy` unset = nothing ever expires (reached 81 GiB once).
- Switching a cluster's archive store makes the plugin delete every `Backup` CR not in the new
  catalog: take a base backup right after, but wait a minute and confirm in the
  `plugin-barman-cloud` log that the options name the new endpoint.
- `kubectl -n velero get backup` resolves to CNPG's CRD. Use `get backup.velero.io`.
- After patching an S3 credential, `rollout restart` every consumer that reads it as env AFTER
  the ExternalSecret synced (teleport-auth failed R2 uploads for two hours that way).

## Pinned versions

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

## DNS

`*.unorouter.com` CNAME to the tunnel covers every host. New hostname: add a `hostname:` rule to
[cloudflared.yaml](infra/cloudflared/cloudflared.yaml), push, then `kubectl -n cloudflared
rollout restart deploy/cloudflared` (config read at startup only).

## tofu

`tofu/.env` (gitignored) exports every `TF_VAR_*`; the state is client-side encrypted.

```sh
cd tofu && tofu init
set -a; source .env; set +a
tofu plan    # read before apply; server ops one node at a time
tofu apply   # manual only
```

Cloud-init writes k3s auto-deploy manifests (Cilium + ArgoCD + root app), so a fresh apply brings
the stack up from git. Prerequisites: the break-glass age key (VeraCrypt volume plus Bitwarden,
loss = secrets unrecoverable), Hetzner token, R2 keys.

### Node disk

Images are the only reclaimable chunk; the rest of the 75G root is live local-path data. Kubelet
`image-gc-high-threshold=70` / `low=55` is set in `tofu/cloud-init*.tftpl` AND
`/etc/rancher/k3s/config.yaml` on each node (keep in sync). Manual prune:

```sh
/var/lib/rancher/k3s/data/current/bin/crictl -r unix:///run/k3s/containerd/containerd.sock rmi --prune
```

`NodeDiskFillingUp` at 75% means GC already ran and the growth is real data.

## Non-negotiable gotchas

- All nodes are k3s SERVERS with `--advertise-address=<private-ip>`. Cilium
  `k8sServiceHost: 127.0.0.1` is valid only while that holds.
- After changing a `--node-ip`: restart the cilium DaemonSet.
- CNPG uses the Barman Cloud PLUGIN. A test-restore from the real bucket is a hard gate.
- ACME HTTP-01 can never reach an origin behind the tunnel: use the `letsencrypt-dns`
  ClusterIssuer (DNS-01).
- Node ops manual, one node per apply, plan reviewed (a both-nodes `-replace` = 34 min DB outage).
- new-api master stays `replicas: 1`. CNPG primaries drift on failover: read
  `status.currentPrimary` every time. Keep the primary in hel1, next to the gateway.
- **The Cilium and ArgoCD HelmChart CRs exist only in the cluster.** Upgrade by patching the live
  CR (`spec.valuesContent`) AND `tofu/cloud-init.yaml.tftpl`, the DR copy. Both carry
  `failurePolicy: abort` and ArgoCD keeps its CRDs, because a re-applied bootstrap file with the
  default `reinstall` policy once uninstalled ArgoCD and every Application vanished.
- ArgoCD polls every 120s + up to 60s jitter with a 3-min repo cache, so a push lands 1.5 to 6
  minutes later. There is no webhook. A CNPG or ScrapeConfig field defaulted by a webhook inside
  an atomic list reads OutOfSync forever: state the default in the manifest.
- Firewall (`tofu/firewall.tf`) allows Tailscale UDP + ICMP only. Never open 22/6443 without a
  source IP and a removal step.
- Org hardening that must stay: base repo permission `none`, member repo creation OFF (the
  ApplicationSet deploys any org repo with `k8s/`), contributions via fork PRs, two org owners.
