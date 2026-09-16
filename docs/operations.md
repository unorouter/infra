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

local-path creates `local` PVs (StorageClass annotation `defaultVolumeType`, 2026-09-16):
Velero's node-agent refuses hostPath-backed claims in every mode and reports the backup
Completed anyway, so a hostPath claim is silently never backed up. Claims from before that
date are hostPath until recreated. A chart-owned claim must never be swapped by pointing
the chart at another claim: ArgoCD prunes the chart's claim the moment it leaves the
rendered manifests and the Delete reclaim policy takes the data with it (Teleport auth,
2026-09-16). Set the PV to Retain first, or keep the claim outside the chart from the start
(`grafana-data`, `teleport`).

## Encryption at rest

`EPHEMERAL` (etcd, images, logs), `s-swap` and `u-local-path-provisioner` (every PVC) carry
LUKS2 with a key derived from the VM UUID (`nodeID`, `talos/patches/volumes.yaml`,
2026-09-17). That covers a disk read away from the VM: a decommissioned drive, a leaked
snapshot, a rescue-mode copy. It does not cover the provider holding the VM (the UUID is
theirs) or the running system. `STATE` (machine config, cluster secrets) stays plain: it can
only be encrypted with a fresh install and Hetzner user data is immutable, so it comes with
the next node swap (`talos/README.md` "A new node"). `talosctl -n <node> get volumestatus`
shows `luks2` in the encryption column; a volume without it has not been re-provisioned yet.

The block is inert on a provisioned volume. Rolling one node (about an hour, one node per
window, rehearsed on a spare 2026-09-17):

1. Preflight as for a node swap (`docs/dr.md`): ArgoCD green, CNPG healthy, WAL archiving,
   primaries known, etcd and OpenBao snapshots fresh, a Velero backup that lists the
   node-pinned local claims to keep (`uno-import-profile`, `data-openbao-0`, anything else
   not rebuildable; hostPath claims must first be recreated as `local`, see Node disk).
2. Cordon, `kubectl cnpg promote` any primary away, evict the singletons one by one, drain,
   delete the node-pinned PVCs (replicas reclone, caches refill, Velero-covered ones come
   back by restore).
3. node11 only: apply a node patch `cluster.controlPlane.endpoint: https://10.200.0.12:6443`
   so its rejoin does not dial itself; undo at the end.
4. Apply the rendered config minus the `UserVolumeConfig` and `SwapVolumeConfig` documents,
   wait until both leave `volumestatus`, then `talosctl wipe disk sda6 --drop-partition`
   and `sda7` (check the partition numbers in `get discoveredvolumes` first).
5. `talosctl apply-config --mode=staged -f <rendered config>` then
   `talosctl reset --graceful --system-labels-to-wipe EPHEMERAL --reboot`. Graceful leaves
   etcd, the other two keep quorum. The node is back with three `luks2` volumes in under a
   minute and rejoins etcd on its own; images re-pull for about ten minutes.
6. Uncordon, watch CNPG reclone, restore the preserved claims, `dr.sh unseal` on node13's
   turn (`dr.sh restore` if the raft data did not come back), `tsh login` on node11's turn.
   Never `--wipe-mode all` or a `STATE` wipe on a Hetzner node: it boots the old user data.

Seen on node11 (2026-09-17): the user volume partition reports `mounted or in use` before
the reboot even with the kubelet stopped, so the drop happens after the reboot instead: the
volume comes up `failed: block dev type mismatch: xfs != luks` (harmless), then apply the
config without the `UserVolumeConfig`, wipe, apply the full config, and it provisions
encrypted in seconds. EPHEMERAL also holds the Tailscale state: the node rejoins the
tailnet as a new device with a new address (`talconfig.yaml` `ipAddress`, the rendered
talosconfig, `~/.claude/CLAUDE.md`, and the old device to delete in the console).

## Gotchas

- All nodes are control planes. etcd, kubelet and Cilium's VXLAN run on the WireGuard mesh
  `10.200.0.0/24` (`talos/talconfig.yaml`, pins in `patches/`), so a node can live at any
  provider or behind NAT. In-cluster clients reach the apiserver through KubePrism
  (`localhost:7445`). Pod Security is `baseline` cluster wide; a workload that needs more gets
  its own labelled namespace (`infra/services/uno-import.yaml`), never a wider exemption.
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
  (cloudflared, unorouter, new-api, redis, newapi-pg), `batch` for deferrable jobs
  (new-api-sync, uno-import, dr-drill). The kubelet evicts by usage over request first, then
  by class, so every serving pod also carries a memory request. Every container carries a
  memory request (7 day median, requests only, no limits); Cilium's are in
  `infra/cilium/values.yaml` and travel with the hand `helm upgrade`. CNPG does not roll pods for a
  class change; it lands when an instance is next recreated (`kubectl cnpg restart <cluster>
  <instance>` one replica at a time, then `kubectl cnpg promote`, then the old primary).
- Kubelet reserves 1Gi/500m for the system (etcd, apid, containerd, tailscaled) and
  512Mi/250m for itself (`talos/patches/machine.yaml`); allocatable is 13.4Gi per node.
- Org hardening: base repo permission `none`, member repo creation OFF (the ApplicationSet deploys
  any org repo with `k8s/`), contributions via fork PRs, two org owners.
- Vector keeps checkpoints and disk buffers under `/var/lib/vector`; a rebuilt node starts from
  the end of every file.

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

## Upgrading

The index of every pin (charts in `apps/`, images in `infra/` and `databases/`, tofu providers,
Talos and Kubernetes in `talos/talconfig.yaml`, ArgoCD in `argocd/kustomization.yaml`) is the
[Dependency dashboard](https://github.com/unorouter/infra/issues?q=is%3Aissue+is%3Aopen+Dependency+dashboard)
issue. Policy in `renovate.json`:

- Patch and minor of images and of charts that roll without an operator step merge to `main`
  before 06:00 on Mondays, seven days after release. ArgoCD rolls the commit.
- Everything else (majors, OpenBao, Teleport, Cilium, ArgoCD, Talos, Kubernetes, operator minors,
  tofu providers) waits in the dashboard until its box is ticked; a tick merges within the hour.
- Renovate never opens a PR. If it does (a branch it cannot rebase), merge or close it that day.
- A bump that misbehaves: `git revert`, then pin it back in `renovate.json` with
  `matchPackageNames` plus `allowedVersions`.

### Steps Renovate cannot take

- **Talos**: `talosctl -n <node> upgrade --image <talosImageURL from talconfig.yaml>:<version>`
  one node at a time (A/B image, rolls back on a failed boot), then the `talosVersion` pin. The
  installer id in `talconfig.yaml` is the current `talos/schematic.yaml`; a schematic change
  lands with the next upgrade, nothing else to do.
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
