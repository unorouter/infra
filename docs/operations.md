# Operations

## DNS

`*.unorouter.com` CNAME to the tunnel covers every host. New hostname: a `hostname:` rule in
[cloudflared.yaml](../infra/cloudflared/cloudflared.yaml), push, `kubectl -n cloudflared rollout
restart deploy/cloudflared` (config read at startup).

## tofu

One module, one client-side encrypted state: nodes, firewall, SSH key and the buckets.
`tofu/.env` (gitignored, never committed) is five exports: `TF_VAR_hcloud_token` (also the
only thing `dr.sh ips` needs, so back it up separately), `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` (the Object Storage key, read by the state backend and the aws
provider), `TF_VAR_state_passphrase` (OpenBao `secret/tofu`) and `TF_VAR_ssh_public_key`
(the Hetzner project key that rescue mode boots with).

```sh
cd tofu && set -a && . ./.env && set +a
tofu plan    # read it; server ops one node at a time
tofu apply   # manual only
```

Servers boot the Talos snapshot (`talos/README.md`) with their rendered machine config as user
data; `./scripts/dr.sh bootstrap` then installs Cilium, ArgoCD and the root app from git. Needed:
the break-glass age key (VeraCrypt plus Bitwarden), Hetzner token, the Object Storage key
(`tofu/.env`), talhelper, talosctl.

## Node disk

Images are the only reclaimable chunk; the rest is live local-path data on the user volume
(`talos/patches/volumes.yaml`). Kubelet image GC is 70/55 % (`talos/patches/machine.yaml`).
`talosctl -n <node> get volumestatus` shows partitions, `image ls` the images.
`NodeDiskFillingUp` at 75 % means GC already ran and the growth is real data.

local-path makes `local` PVs (StorageClass annotation `defaultVolumeType`): Velero's node-agent
skips hostPath claims yet reports the backup Completed. Never swap a chart-owned claim by
pointing the chart at another one: ArgoCD prunes the old claim and the Delete policy takes its
data (Teleport auth, 2026-09-16). Set the PV to Retain first, or keep the claim outside the
chart (`grafana-data`, `teleport`).

## Log store (ClickHouse)

Gateway `logs` and `audit_logs` live in ClickHouse since 2026-10-04 (`LOG_SQL_*` in OpenBao
`secret/newapi-env`; `infra/databases/clickhouse/clickhouse.yaml`, `clickhouse/keeper.yaml`). Three
replicas and three Keeper members, one of each per node. Every replica accepts writes and
fetches the others' parts within seconds; there is no primary. The `clickhouse` Service routes
only to a replica whose two tables exist, reach Keeper and are under 5 minutes behind; without
a Keeper majority all drop out and rows wait in the spool. Parts older than 30 days move to
`unorouter-clickhouse` through an `encrypted` disk (key OpenBao `secret/clickhouse`
`cold_key_hex`, no other copy).

- Accounts: `admin`; `gateway` may only SELECT, INSERT and CREATE TABLE on the two tables
  (append only, like `protect-audit-logs.sql`); `reader`; `security_exporter`
  (`clickhouse/sql/security.sql`). The dictionaries read newapi-pg as `clickhouse_dict`.
- Schema, TTL and index changes are admin's, by hand (`clickhouse/sql/logs-indexes.sql`); the
  gateway issues no ALTER.
- A failed write goes to Postgres `log_spool`; the master drains it every 5 s, skipping rows
  ClickHouse already has. `GatewayLogRowsLost`: a row reached neither. `GatewayLogSpoolBacklog`:
  the spool stayed non-empty 15 minutes.
- `system.metric_log` stays off (on 25.8 a merge of its 1,435 columns reserves about 5 GiB).
  The config is subPath mounted: a ConfigMap change needs a rolling restart.
- Query: `kubectl -n databases exec -it clickhouse-0 -- clickhouse-client --user reader
  --password "$CH_READER_PASSWORD"`, or the Teleport app `clickhouse` (`tsh proxy app
  clickhouse --port 18123`). Backup and restore: `docs/dr.md` "ClickHouse".

## Encryption at rest

Every Talos volume (`STATE`, `EPHEMERAL`, swap, the local-path volume) is LUKS2 with a key derived
from the VM UUID (`nodeID`, `talos/patches/volumes.yaml`), on every node since 2026-09-17 and on
a new node from its first boot. It covers a disk read away from the VM (a decommissioned drive,
a leaked snapshot, a rescue-mode copy), not the provider holding the VM or the running system.
`talosctl -n <node> get volumestatus` shows `luks2` per volume; a node that refuses its key is
in `docs/dr.md` "Encrypted volumes".

## Gotchas

- All nodes are control planes. etcd, kubelet and Cilium's VXLAN run on the WireGuard mesh
  `10.200.0.0/24` (`talos/talconfig.yaml`, pins in `patches/`), so a node can live at any
  provider or behind NAT. In-cluster clients reach the apiserver through KubePrism
  (`localhost:7445`). Pod Security is `baseline` cluster wide; a workload that needs more gets
  its own labelled namespace (`infra/services/uno-import.yaml`), never a wider exemption, plus
  a ValidatingAdmissionPolicy that holds the namespace to baseline with only the one exception
  it needs (uno-import: `NET_ADMIN` on the `vpn` container).
- During a node address change, policy-restricted pods cannot reach the new address (Cilium
  calls it "world") until the kubelet reports it.
- CNPG uses the Barman Cloud plugin. A test restore from the real bucket is a hard gate.
  Primaries drift on failover: read `status.currentPrimary` every time. new-api master stays
  `replicas: 1`.
- ACME HTTP-01 never reaches an origin behind the tunnel: `letsencrypt-dns` ClusterIssuer.
- Cilium (`infra/cilium`) and ArgoCD (`argocd/`) are applied by `dr.sh bootstrap` before ArgoCD
  exists and owned by git afterwards.
- ArgoCD polls every 120 s plus jitter with a 3 min repo cache: a push lands in 1.5 to 6 min,
  there is no webhook. A field defaulted by a webhook inside an atomic list reads OutOfSync
  forever: state the default in the manifest. A duplicate rule group name fails the SSA diff
  and silently stops the monitoring app; check `.status.conditions` before suspecting drift.
- Two firewalls in series. Hetzner (`tofu/nodes.tf`): Tailscale UDP, mesh UDP from the node
  addresses, ICMP. Talos (`talos/patches/firewall.yaml`, nftables input, default block, applied
  live): mesh tcp 2379-2380, 4240, 6443, 10250, 50000-50001 and udp 8472; WireGuard 51820 from
  the peer endpoints; 6443 and 50000 from the tailnet; pod clients of host ports (Prometheus,
  hubble-relay, etcd-backup, every ClusterIP client of the kube API). A pod reaching another
  node's address is masqueraded to its own node's mesh address (not encapsulated), so a
  scraped port must be in the `mesh-tcp` rule; the `pods` rule only covers same-node clients.
  A new node's endpoint goes into the `wireguard` rule and `local.nodes`. Never open 22 or 6443 without a source IP and a removal step. Cilium
  answers NodePort and LoadBalancer in BPF before the chain: the node firewall cannot guard
  those, so the cluster has none. Change it with `apply-config --mode=try --timeout=6m` first.
- PriorityClasses (`infra/services/priorityclasses.yaml`): `serving` for the revenue path
  (cloudflared, unorouter, new-api, redis, newapi-pg), `batch` for deferrable jobs. The kubelet
  evicts by usage over request first, then by class, so every container carries a memory
  request (7 day median); Cilium's live in `infra/cilium/values.yaml` and travel with the hand
  `helm upgrade`. CNPG applies a class change only to a recreated instance (`kubectl cnpg
  restart`, replicas first, then promote, then the old primary).
- Kubelet reserves 1Gi/500m for the system (etcd, apid, containerd, tailscaled) and
  512Mi/250m for itself (`talos/patches/machine.yaml`); allocatable is 13.4Gi per node.
- Org hardening: base repo permission `none`, member repo creation OFF (the ApplicationSet deploys
  any org repo with `k8s/`), contributions via fork PRs, two org owners.
- Vector keeps checkpoints and disk buffers under `/var/lib/vector`; a rebuilt node starts from
  the end of every file.
- A `newapi-pg` switchover is never free: about ten seconds of `failed to connect` in new-api,
  120 to 230 extra 500s (2026-09-17 by day, 2026-09-29 by night). Rolling several nodes, park
  the primary once on a node that is already done. Watch with an endpoint that needs the
  database; `/api/status` and `/api/pricing` answer from cache.
- Both Postgres clusters run `podAntiAffinityType: required`, so a replacement replica stays
  Pending until its node is back. `newapi-pg` runs `primaryUpdateStrategy: supervised`: a spec
  change waits in `Waiting for user action` (ArgoCD shows `new-api` Degraded) until `kubectl
  cnpg promote newapi-pg <replica> -n databases`.
- A PV left `Released` blocks a Velero restore of the same claim: delete it first.
- Reinstalling node11: its config needs `cluster.controlPlane.endpoint:
  https://10.200.0.12:6443` so it does not dial itself. Talos derives
  `--service-account-issuer` from it, so that apiserver rejects every token until the normal
  config is back: apply it the moment the node shows in `etcd members`.
- A Hetzner `rebuild` (same server, id, address and VM UUID) takes `image` plus `user_data`.
  Send the config without the `UserVolumeConfig` document and apply the full one once `s-swap`
  is ready, or the user volume takes the swap's space. Never `--wipe-mode all` or a `STATE`
  wipe on a Hetzner node: it boots the old user data.
- A wiped `EPHEMERAL` holds the Tailscale state: the node rejoins as a new device with a new
  address (`talconfig.yaml` `ipAddress`, the rendered talosconfig, the old device to delete).
- OpenBao's PodDisruptionBudget blocks a drain; `dr.sh restore` and `dr.sh unseal` need the
  VeraCrypt volume mounted before the drain, not after.

## Deploying a service

**A repo with a `k8s/` directory deploys itself**, no commit here.

1. App repo: `k8s/` with Deployment and Service (`namespace: services`), an ExternalSecret on an
   existing OpenBao key, optionally CNPG `Cluster`, `ObjectStore` and `ScheduledBackup`
   (`namespace: databases`). Its `CiliumNetworkPolicy` goes in
   `infra/services/networkpolicies.yaml` here: the namespace is default-deny.
2. Push. [apps/appset-services.yaml](../apps/appset-services.yaml) scans the org and creates the
   Application within about 15 min.
3. Every push to `main` runs the `GHCR Image` workflow: multi-arch build, then a
   `deploy(<repo>): <sha>` pin commit by `unorouter-ci`, ArgoCD rolls it in 10 to 20 min. Copy the
   workflow from new-api, keep `paths-ignore` on `k8s/**` and `**.md`.

- `renovate[bot]` commits are the weekly dependency bumps ([Upgrading](#upgrading)); `git
  revert` undoes one.
- Pin images to a git SHA, never `:latest`: a floating tag changes no manifest, nothing deploys.
- No build secrets. Builds use committed public configuration (`NEXT_PUBLIC_*` in
  `.env.public`); secrets arrive at runtime from the ExternalSecret. There is no local build
  path: Actions down means wait.
- A deploy is done when ArgoCD shows the new image, never because a push or workflow succeeded.
- Generated apps run under the restricted `apps` AppProject: `services` and `databases` only,
  no cluster-scoped resources.
- `k8s/` is a deploy gate: write access to an org repo is write access to the cluster.

## Pod isolation

Every workload namespace is default-deny (plain `NetworkPolicy`, empty selector, Ingress and
Egress) plus one `CiliumNetworkPolicy` per workload in `infra/<ns>/networkpolicies.yaml`. A pod
reaches only its dependencies, and the internet only on the ports its code dials. DNS and the
API server are not in those files: `infra/services/cluster-egress.yaml` grants kube-dns to
every pod of the listed namespaces and 6443 to pods with their own ServiceAccount (three SAs
excluded). A new isolated namespace goes into both lists; a workload that only needs DNS and
the API server needs no policy of its own (Cilium rejects a rule-less spec).

- **Never `toFQDNs` or a DNS L7 rule here**: with socket-LB, vxlan and legacy host routing the
  DNS proxy drops every redirected query (cilium/cilium#46284). Internet egress is `toCIDR` where
  documented, else `toEntities: [world]` on named ports.
- Ports in rules are container ports. The API server is `[host, remote-node, kube-apiserver]`
  (admission webhooks arrive from those). Kubelet probes arrive as `host`.
- A policy regression is a number: `hubble_drop_total{reason="POLICY_DENIED"}` by `source`
  and `destination` namespace (agent port 9965), zero in steady state. Check it after every
  policy change instead of watching pods fail.
- Helm and ArgoCD hook Jobs run under their own ServiceAccount and are enforced from birth: put
  them in a selector first or the sync wedges on `hook-finalizer`.
- Run `hubble observe --verdict DROPPED --since 60m` an hour after any policy change. Clients
  that only talk on user action (Grafana verifying a JWT, a watcher paging Alertmanager) never
  show in a quiet 10 min window.

## Rotating cluster secrets

Every key lives in `talos/talsecret.sops.yaml` or `talos/talenv.sops.yaml`; render on the
laptop, apply, shred the render. Order and traps from the 2026-09-29 rotation:

- **Talos and Kubernetes API CAs**: `talosctl rotate-ca`, graceful. Afterwards re-mint the
  talosconfig Secrets `talos-etcd-backup` and `talos-apid-reader` in kube-system.
- **Service account key**: no dual accept on Talos, every pod token dies at once; switch the
  CNPG primaries to freshly restarted replicas first.
- **Secretbox key**: `patches/etcd-encryption.yaml`. New key second, roll every apiserver;
  new key first, roll; `kubectl get secrets -A -o json | kubectl replace -f -`; drop the old
  key. Each apply restarts the apiservers a minute later, one node at a time: wait for the
  container start time to pass the apply before the next step.
- **WireGuard keys and trustd token**: with the Talos upgrade, one node at a time (the node
  gets them staged, the others the new public key live the moment it reboots).
- **etcd CA** (no graceful path in Talos): new `certs.etcd` in talsecret, CNPG isolation check
  off on both clusters first (`probes.liveness.isolationCheck.enabled: false` in the app repos'
  `k8s/pg.yaml`, applies live). Applying the CA writes the files only: etcd, the apiserver and
  machined's own etcd client keep the old CA in memory, and the Talos API cannot restart etcd.
  Reboot one node at a time (drained, primaries and singletons moved off first): the first
  rebooted node drops out, the second one forms the new quorum with it, the third rejoins.
  Do not restart etcd alone (SIGTERM through a host PID pod): machined keeps its old client,
  reports etcd unhealthy and withdraws the apiserver, which on 2026-09-29 took the kube API
  away on all three nodes for about ten minutes until each node was rebooted. Isolation
  check back on at the end.

## Upgrading

The index of every pin (charts in `apps/`, images in `infra/` and `databases/`, tofu providers,
Talos and Kubernetes in `talos/talconfig.yaml`, ArgoCD in `argocd/kustomization.yaml`) is the
[Dependency dashboard](https://github.com/unorouter/infra/issues?q=is%3Aissue+is%3Aopen+Dependency+dashboard)
issue. Policy in `renovate.json`:

- Patch and minor of images and of charts that roll without an operator step merge to `main`
  before 06:00 on Mondays, seven days after release. ArgoCD rolls the commit.
- Everything else (majors, OpenBao, Teleport, Cilium, ArgoCD, Talos, Kubernetes, operator minors,
  tofu providers) waits in the dashboard until its box is ticked; a tick merges within the hour.
- Images are pinned `tag@sha256`. Renovate pins new ones and merges digest bumps with patch and
  minor, which is how a floating tag such as `python:3.14-alpine` still picks up fixes.
- Renovate never opens a PR. If it does (a branch it cannot rebase), merge or close it that day.
- A bump that misbehaves: `git revert`, then pin it back in `renovate.json` with
  `matchPackageNames` plus `allowedVersions`.

### Steps Renovate cannot take

- **Talos**: `talosctl -n <node> upgrade --image <talosImageURL from talconfig.yaml>:<version>`
  one node at a time (A/B image, rolls back on a failed boot). The installer id in
  `talconfig.yaml` is the current `talos/schematic.yaml`; a schematic change lands with the next
  upgrade, nothing else to do. The 1.14.1 roll (2026-09-29) set the order:
  1. Use the talosctl of the target version. It cordons from the laptop against
     `cluster.controlPlane.endpoint` (a mesh address the laptop cannot reach), so drain first
     with `kubectl drain` (Teleport, or a `talosctl kubeconfig` pointed at a tailnet address when
     the node holds Teleport auth) and upgrade with `--drain=false`.
  2. Pre-pull the next etcd image into the system namespace
     (`talosctl image pull --namespace system registry.k8s.io/etcd:<version>`, the version from
     the release notes): a boot that cannot pull it leaves etcd `Failed` in its pre stage, and
     etcd cannot be restarted through the API, only by another reboot.
  3. Never park a singleton by cordoning a node that holds a CNPG primary: CNPG switches the
     primary over at once when its node turns unschedulable.
  4. OpenBao on the node comes back sealed: `dr.sh unseal` with the VeraCrypt volume mounted.
     After Teleport auth moved, restart the proxies and `teleport-app-access-0`.
  `talosVersion` in `talconfig.yaml` is the config contract and stays at the older minor until
  the v1alpha1 cluster patches move to the new documents (see the comment there).
  **Kubernetes**: `talosctl -n <node11> upgrade-k8s --to <version>` walks every node, then the
  `kubernetesVersion` pin.
- **ArgoCD** and local-path are bootstrap-applied, not ArgoCD-managed: after the merge
  `kubectl apply -k argocd/ --server-side --force-conflicts` (or `-k infra/local-path`) as in
  dr.sh.
- **OpenBao**: the StatefulSet is `OnDelete`. After the merge delete the pod, then unseal (3 of 5):
  `dr.sh unseal` talks to the break-glass kubeconfig (`dr.sh kubeconfig` first), or run its
  loop by hand against the Teleport kubeconfig. Until unsealed, `KubeStatefulSetUpdateNotRolledOut`
  fires and ESO cannot sync new values; existing Secrets keep working.
- **Teleport**: auth chart and kube agent chart are one group; auth rolls first, agents reconnect.
- **tofu providers**: constraint and `.terraform.lock.hcl` change together; `tofu init -upgrade`
  and `tofu plan` before trusting the next apply.
- **Operators (cert-manager, CNPG, Barman plugin)**: read the release notes for CRD changes before
  ticking a minor; a patch merges on its own.
