# k0s migration

Goal: the same stack, from git, on k0s, with the leanest possible operator surface. One
declarative file for the cluster (`k0sctl.tmpl.yaml`), git for everything above it, no live-only
objects, no bootstrap files that re-apply themselves on a restart.

Lean rules for the new cluster:

- If it is not in git it does not exist. The only exceptions are secrets in OpenBao and the
  rendered `k0sctl.yaml` (node IPs, gitignored).
- Bootstrap installs exactly two charts (Cilium, ArgoCD) and one manifest (`root-app.yaml`).
  Everything else is an Application in `apps/`.
- No bundled extras: kube-proxy off, kube-router off, no Traefik, ServiceLB, klipper-helm,
  metrics-server from the distribution. What the stack needs comes from `apps/`.
- Nodes are `controller+worker`, untainted, until a fourth node exists; then databases move
  off the etcd voters by label.
- Admin over Tailscale only. A spare is joined by an operator, on purpose, one at a time; no
  automation holds a tailnet key.

## 0. Prerequisites

- Three cx43 spares parked by `scripts/hetzner-snipe.sh` (`SNIPE_COUNT=3`, any EU DC). The
  sniper only buys; it holds no tailnet key. Join each spare yourself with
  `./spare-join.sh unorouter-spare-<loc>-<n>` (opens 22 for your IP, installs Tailscale with a
  key read from OpenBao at run time, closes 22 again) and check `tailscale status`.
- `k0sctl` on the laptop (`~/.local/bin/k0sctl`), `tofu/.env` for the Hetzner token.
- Both CNPG restores rehearsed against the real bucket within the last week (hard gate).
- OpenBao raft snapshot taken right before the flip, unseal keys at hand.

## 1. Bootstrap (nothing live is touched)

```sh
cd bootstrap/k0s
./gen-k0sctl.sh                 # hosts + SANs from Hetzner API and tailscale status
k0sctl apply --config k0sctl.yaml
k0sctl kubeconfig --config k0sctl.yaml > ../../kubeconfig.k0s
export KUBECONFIG=$PWD/../../kubeconfig.k0s
kubectl get nodes; kubectl -n kube-system get pods   # cilium up, kube-router absent
kubectl -n argocd get app                              # root app synced from apps/
```

ArgoCD creates every Application. Before the first sync completes, turn automated sync OFF on
the five that must not run twice while the old cluster still serves: `new-api`,
`new-api-sync`, `unorouter-bot`, `cloudflared`, `openbao-snapshot` (and keep Velero's schedule
paused). They stay at their pinned SHA and are synced by hand at the flip.

## 2. State

- OpenBao: restore the raft snapshot, unseal (3 of 5), ESO reconciles every secret. Freeze
  secret edits on the old cluster from snapshot to flip.
- CNPG: `newapi-pg` and `bot-pg` as replica clusters (`bootstrap: recovery` from the current
  `-v4` prefixes, `replica.enabled: true`), archiving to new `-v5` prefixes. They replay WAL from
  S3 continuously; set `archive_timeout` to 60 s on the old primaries for the migration week.
  Verify with row counts against the old primaries.
- Teleport: re-apply `infra/teleport/resources/` with tctl, delete the agent's
  `teleport-app-access-0-state` Secret if it exists, let the agent join.
- Prometheus history is not migrated.
- Add the new node private IPs and public IPs to `TRUSTED_NETWORKS` and the edge skip rule
  next to the old ones for the overlap.

## 3. Flip (about five minutes of no writes)

1. Old cluster: scale `new-api-master`/`new-api-slave` and `unorouter-bot` to 0, suspend
   `new-api-sync` and the snapshot CronJob.
2. Old primaries: `SELECT pg_switch_wal();` on both, wait for the archive upload.
3. New replica clusters: confirm replayed LSN, then `replica.enabled: false` (promote).
4. New cluster: sync `new-api`, `unorouter-bot`, `new-api-sync`, then `cloudflared` (3 replicas).
5. Old cluster: cloudflared to 0. Traffic is on the new cluster. Watch `/api/status`, the
   tunnel stream count, and a real chat request end to end.
6. Soak one day. Old cluster stays powered but idle.

## 4. After

- Delete node8, node9, node10 with tofu (state reconciled), remove their IPs from
  `TRUSTED_NETWORKS`, the edge skip rule, `scrape-etcd.yaml`, and the DR README.
- Rename spares to `unorouter-node11..13` in tofu (import) and `hostname` in `k0sctl.yaml`.
- Sniper back to per-region mode (`SNIPE_COUNT=1`, `SNIPE_LOCS=<missing DC>`) to restore the
  three-DC spread with one rolling swap per catch: join the new node with `k0sctl apply`,
  move stateful pods with the node-swap runbook, `k0s etcd leave` on the old one, delete.
- Upgrades from now on: bump `spec.k0s.version`, `k0sctl apply`, one node at a time by the tool.

Known k0s behaviours to respect: `/var/lib/k0s/manifests/*` is re-applied by the manifest
deployer on every restart (only `root-app.yaml` lives there, and it is idempotent); charts in
`extensions.helm` are reconciled from the config, so ArgoCD's own values change through
`k0sctl apply`, never by hand.
