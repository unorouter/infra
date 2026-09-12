# Disaster Recovery runbook

Three Talos Linux control planes with embedded etcd in nbg1, private net 10.100.1.0/24
(node11 .1, node12 .5, node13 .6); etcd and the kubelet are pinned to that subnet. Public IPs are
not in git: `./scripts/dr.sh ips` asks the Hetzner API with only the token, so it works with no
tofu state, no S3 and no cluster. Nodes have no SSH and no shell: `talosctl` over the tailnet
(`TALOSCONFIG=bootstrap/talos/clusterconfig/talosconfig`, rendered from sops, never committed).
Every command below is a `dr.sh` subcommand, a `bootstrap/talos` script or a hand step; access
paths and break-glass credentials are in [docs/access.md](../../docs/access.md), bucket layout
and the restore drill in [docs/backups.md](../../docs/backups.md), the node lifecycle in
[../talos/README.md](../talos/README.md).

Stateful placement: Prometheus, Alertmanager, Grafana and Loki on node12 (`nodeSelector`,
label `unorouter.com/monitoring`), OpenBao, ArgoCD and Teleport wherever their PV landed, CNPG
newapi-pg 3 instances and bot-pg 2 on local-path PVs. Losing a node loses those PVs; everything
below is how they come back.

## Rules that hold in every scenario

- One node per tofu apply, plan read, exactly one destroy. A both-nodes `-replace` cost 34
  minutes of database writes on 2026-07-23.
- Check `kubectl -n databases get cluster` for the primaries before any node surgery; drills and
  failovers move them. A raw `status.targetPrimary` patch is never the right tool
  (`kubectl cnpg reload` was what that session wanted, 2026-09-02).
- Memory: limits only on the revenue services, none on Postgres, Prometheus, etcd and the
  platform (they cache on purpose). Nodes carry 4 GiB host swap that pods cannot use
  (`failSwapOn: false` with kubelet `NoSwap`, `bootstrap/talos/patches/machine.yaml`).
- Liveness probes are `tcpSocket` only; killing a pod never fixes a slow dependency.
- Node names are cattle: the next number, set in `talconfig.yaml`. A replacement never reuses
  a name.
- Never `talosctl edit mc`: edit `bootstrap/talos/patches`, render, `apply-config`. Never
  render before the patches carry every live setting (the subnet pins were missing until
  2026-09-12 and a render would have dropped them).
- Pod Security is `baseline` cluster wide (`patches/cluster.yaml`). A workload that needs more
  gets its own labelled namespace (`infra/services/uno-import.yaml`), never a wider exemption.

## Rebuild from total loss

**Survives**: Hetzner Object Storage (its own tofu state under `tofu/storage/`, `prevent_destroy`),
the Talos snapshot on Hetzner (`upload-image.sh` rebuilds it from Image Factory otherwise), git,
sops files in git, the break-glass age key (VeraCrypt plus Bitwarden), Cloudflare DNS and the
tunnel token in the vault snapshot.
**Dies**: nodes, etcd, every local-path PV (PGDATA, OpenBao raft, Teleport SQLite, ArgoCD,
monitoring), every pod.

0. **Pre-destroy on a live cluster**: scale the writers to 0 (new-api master and slaves, bot,
   unorouter, mcp, uno-import), suspend the sync and archive CronJobs, `SELECT pg_switch_wal()`
   and confirm the segment archived, force a fresh OpenBao snapshot
   (`kubectl -n openbao create job --from=cronjob/openbao-raft-snapshot ...`), commit the lineage
   bump (step 2), then destroy. Skipping the WAL flush loses the last five minutes of writes.
1. **Recreate**: `sops -d secrets/talos.sops.yaml > bootstrap/talos/talsecret.yaml`, render
   (`bootstrap/talos/README.md`), `./scripts/dr.sh apply`. Each server boots the Talos snapshot
   with its machine config as user data. `./scripts/dr.sh bootstrap` runs `talosctl bootstrap`
   on the first node, installs Cilium, ArgoCD (`bootstrap/argocd`) and the root app, all from
   git. Hand-applied objects that no Application owns: `infra/databases/networkpolicies.yaml`,
   `apps/appproject-apps.yaml`, `apps/appset-services.yaml`.
2. **Bump the CNPG lineage**, the one unavoidable edit: CNPG halts a restored primary that
   archives to the path it restored from. The manifests live in the app repos
   (`unorouter/new-api` and `unorouter/unorouter-bot`, `k8s/pg.yaml`): set
   `plugins[].serverName` to v{N+1}, `externalClusters[<x>-origin].serverName` to v{N} (the
   archive that holds the data, v8 since 2026-09-12), remove the `replica` block, set `LINEAGE`
   in `databases/dr-drill.yaml` to v{N}, push before the apply. Never set
   `cnpg.io/skipEmptyWalArchiveCheck` (corrupts the source). PITR:
   `bootstrap.recovery.recoveryTarget.targetTime` before the apply, removed after. Recovery
   jobs fail until ESO delivers the S3 secret and the s3-gateway answers on `s3.unorouter.com`
   (CoreDNS rewrite, monitoring app); the jobs also need the `cnpg-jobs` policy. A joining
   replica needs the timeline history file of the current timeline in the archive
   (`0000001C.history` was missing from v7 and had to be written from the primary's `pg_wal`).
3. **Restore OpenBao**: `./scripts/dr.sh restore` (temp init, snapshot from
   `openbao-snapshots/latest.snap` with the `pg-s3` pair from sops, restart). The script waits
   for Ready before unsealing and a sealed pod is never Ready, so finish with
   `./scripts/dr.sh unseal` and `kubectl -n external-secrets rollout restart deploy/external-secrets`,
   then force-sync every ExternalSecret. Then `tsh login` again, the Teleport CA is new.
   Age key lost: unseal keys are in Bitwarden, `dr.sh unseal` by hand.
4. **Hand steps git does not carry**:
   - `psql -U postgres -d newapi -f infra/databases/quota-audit.sql` and
     `reader-least-privilege.sql` after a cluster built from `initdb`. A physical restore keeps
     roles, triggers and RLS; an initdb cluster comes back with `reader` able to read every
     PAT and password hash.
   - OpenBao OIDC role is a runtime write, send every field:
     ```sh
     bao write auth/oidc/role/admin \
       allowed_redirect_uris='https://openbao.unorouter.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback' \
       user_claim=email token_policies=admin bound_audiences=openbao \
       oidc_scopes=openid,profile,email,groups groups_claim=groups \
       token_ttl=168h token_max_ttl=768h
     ```
     and `bao auth tune -listing-visibility=unauth oidc/` so the UI opens on OIDC.
   - Teleport is stateless: reapply `infra/teleport/resources/*.yaml` (connector secret from
     OpenBao `teleport-github`), rebuild the `newapi-pg-client-ca` bundle with a fresh
     `tctl auth export --type=db-client` (own client CA first, `ca.key` stays SEC1), then the
     agent identity: scale `teleport-app-access` to 0, delete `teleport-app-access-0-state`,
     scale to 1.
   - `kubectl -n dex rollout restart deploy/dex` and the same for cloudflared after any hostname
     change; both read config at boot.
   - The edge rule "machine surface ... own nodes" lists the node public addresses
     (`infra/cloudflare/unorouter.com/rules*.sops.yaml`); new nodes sit in a datacenter ASN the
     challenge rule targets, so in-cluster probes fail until the set is updated and applied.
   - Kubernetes auth in OpenBao and Velero's first sync self heal; restart ESO if it cached a
     failure, clear the Velero operation and refresh.
5. **Done when** the platform apps are Synced and the app repos reappear as Applications
   (`kubectl -n argocd get app`), both CNPG clusters are healthy with WAL replay, services answer
   200 through the tunnel, the blackbox probes pass and SSO works.

## Node swap (zero downtime)

Drive it from `./scripts/dr.sh kubeconfig`: the Teleport context routes through the in-cluster
apiserver Service, which loses endpoints mid-swap.

0. **A sniped spare** (`bootstrap/hetzner-snipe.sh`) boots the snapshot with no config and waits
   in maintenance mode behind the node firewall. Give it the next name in `talconfig.yaml` with
   the private IP Hetzner assigned, render, `bootstrap/talos/spare-join.sh <server> <node>`.
1. **Preflight**: primaries known, ArgoCD green, WAL archiving true, the old node's data fits
   the new disk.
2. **Join first**: the spare becomes the fourth etcd member, quorum never dips. Wait for 4 Ready,
   `talosctl -n <new> etcd status` and cilium-health 4/4 (about three minutes).
3. **Evacuate**: cordon, evict singletons one at a time as `kubectl delete pod` with a Ready
   check between (new-api master, bot, cilium-operator, teleport-app-access-0), then
   `drain --ignore-daemonsets --delete-emptydir-data`.
4. **Postgres replicas** stay Pending on node-pinned PVCs: delete PVC and pod, CNPG re-clones
   from the primary, one cluster at a time (3/3 then 2/2, one to six minutes each). Monitoring
   PVCs on the old node: delete them, or rsync the immutable TSDB block dirs into the new PV first.
5. **Remove**: `talosctl -n <old> reset` (graceful, leaves etcd itself), `kubectl delete node`,
   then `tofu plan -destroy -target=hcloud_server.nodeX -out=f`, read it (exactly one destroy),
   `tofu apply f`. `talosctl etcd remove-member` only for a node that is already gone.
6. **Import**: add the node.tf block (`ignore_changes [user_data, ssh_keys]`), `tofu import`,
   apply the in-place reconcile (abort on any replace), final plan is No changes. Update the
   etcd target list in `infra/monitoring/extras/scrape/etcd.yaml`, the SANs in
   `talconfig.yaml` and the own-nodes edge rule in the same change or alerts and probes go blind.

## Quorum loss

Two of three members gone: apiserver down, CNPG cannot promote, public reads keep serving.
Nightly etcd snapshots sit in `unorouter-backups/etcd/<node>/` (`infra/talos/etcd-backup.yaml`).

1. `talosctl -n <dead or rejoining nodes> reset --graceful=false` so they do not fight the
   recovery.
2. On the survivor: `talosctl -n <node> bootstrap --recover-from <snapshot> --recover-skip-hash-check`
   after fetching the newest snapshot through the crypt gateway.
3. Rejoin the others one at a time (`spare-join.sh` shape: rebuild to the snapshot, apply
   config). Proven twice on the spares on 2026-09-10.

## No tailnet

1. Hetzner Cloud Firewall: temporary inbound 50000 for your current IP, `talosctl -e <public ip>`,
   remove the rule. Port 22 does not exist on Talos.
2. Hetzner console shows the Talos dashboard; there is no login. Rescue mode boots with your key
   and can mount the disk.

Joining a rebuilt node to the tailnet is part of the machine config (`tailscale` extension with
the pre-signed `talos_auth_key` from OpenBao `secret/tailscale`); rotate it in the admin console,
sign it for Tailnet Lock, `bao kv patch secret/tailscale talos_auth_key=@-`.

## Cluster switchover (executed 2026-09-12, k3s to Talos)

Recorded because it is the template for any future move between clusters or datacenters.
Both databases ran as CNPG replica clusters on the new site, restored from the old archive and
streaming from the old primaries over the tailnet, with distributed topology names
`<x>-origin` (old archive) and `<x>-talos` (new archive) on both sides.

1. New site fully prepared: vault restored from a fresh snapshot, its own Cloudflare tunnel with
   shadow hostnames, images pre-pulled, AppProject and SCM secret present, replicas at
   sub-second lag.
2. Freeze writers on the old site (apps to 0, crons suspended, old ArgoCD controller to 0).
3. Demote: `kubectl -n databases patch cluster <x> --type=merge -p '{"spec":{"replica":{"primary":"<x>-talos"}}}'`
   on the old site. CNPG fences every instance, archives the shutdown checkpoint as `.partial`
   and writes `status.demotionToken` (nine seconds).
4. Promote on the new site with both fields in one patch:
   `{"spec":{"replica":{"primary":"<x>-talos","promotionToken":"<token>"}}}`. A token-less
   primary flip is a failover and rebuilds the old site instead.
5. Push the post-switch manifests, apply the ApplicationSet, smoke the shadow hostnames, move
   the wildcard and apex CNAMEs to the new tunnel. The edge keeps sending a share of traffic to
   the old tunnel for about three minutes after the DNS change.
6. The old site follows the new one as a replica: rollback is the same token exchange in
   reverse plus the two DNS records, until teardown.

Write outage 72 seconds, user-facing errors about four and a half minutes including the edge
cache. Post-flip fixes that a future move needs from the start: own-nodes edge rule, metrics-server
(k3s shipped one, Talos does not), ArgoCD PodMonitor by port number, the uno-import namespace.
