# Disaster Recovery runbook

Three k3s servers with embedded etcd, private net 10.100.0.0/16 (node8 hel1 .3, node9 nbg1 .2,
node10 hel1 .4); quorum survives a DC outage. Public IPs are not in git: `./scripts/dr.sh ips`
asks the Hetzner API with only the token, so it works with no tofu state, no S3 and no cluster.
Every command below is a `dr.sh` subcommand or a hand step; access paths and break-glass
credentials are in [docs/access.md](../../docs/access.md), bucket layout and the restore drill in
[docs/backups.md](../../docs/backups.md).

Stateful placement today: OpenBao and ArgoCD on node8, Prometheus, Alertmanager, Grafana and
Loki on node9 (`nodeSelector`), CNPG newapi-pg 3 instances and bot-pg 2 on local-path PVs.
Losing a node loses those PVs; everything below is how they come back.

## Rules that hold in every scenario

- One node per tofu apply, plan read, exactly one destroy. A both-nodes `-replace` cost 34
  minutes of database writes (`incidents/2026-07-23-quorum-loss.md`).
- Check `kubectl -n databases get cluster` for the primaries before any node surgery; drills and
  failovers move them, and a raw `status.targetPrimary` patch is never the right tool
  (`incidents/2026-09-02-primary-moves.md`).
- Memory: limits only on the revenue services, none on Postgres, Prometheus, etcd and the
  platform (they cache on purpose). Nodes carry 4G host swap that pods cannot use
  (`fail-swap-on=false` with kubelet `NoSwap`), confirm after a k3s restart with
  `journalctl -u k3s | grep "NoSwap is set"`.
- Liveness probes are `tcpSocket` only; killing a pod never fixes a slow dependency
  (`incidents/2026-07-23-frontend-crashloop.md`).
- Node names are cattle: k3s bakes the name at registration, a replacement takes the next number.

## Rebuild from total loss

**Survives**: Hetzner Object Storage (its own tofu state under `tofu/storage/`, `prevent_destroy`),
git, sops files in git, the break-glass age key (VeraCrypt plus Bitwarden), Cloudflare DNS.
**Dies**: nodes, etcd, every local-path PV (PGDATA, OpenBao raft, Teleport SQLite, ArgoCD,
monitoring), every pod.

0. **Pre-destroy on a live cluster**: scale the writers to 0 (new-api master and slaves, bot),
   `SELECT pg_switch_wal()` and confirm the segment archived, force a fresh OpenBao snapshot
   (`kubectl -n openbao create job --from=cronjob/openbao-raft-snapshot ...`), commit the lineage
   bump (step 2), then destroy. Skipping the WAL flush loses the last five minutes of writes.
1. **Recreate**: `./scripts/dr.sh apply`. Cloud-init installs k3s (`tofu/variables.tf`
   `k3s_version`), writes the Cilium and ArgoCD HelmChart CRs and the root app, so the apply
   alone brings the platform back from git. The first node runs `--cluster-init`, the others
   retry the join until its apiserver is up (minutes of join errors at boot are normal).
   `./scripts/dr.sh bootstrap` is the fallback if the HelmChart path fails. Reused IPs: `ssh-keygen -R`.
2. **Bump the CNPG lineage**, the one unavoidable edit: CNPG halts a restored primary that
   archives to the path it restored from. The manifests live in the app repos
   (`unorouter/new-api` and `unorouter/unorouter-bot`, `k8s/pg.yaml`): set
   `plugins[].serverName` to v{N+1}, leave `externalClusters[].serverName` at v{N}, set
   `LINEAGE` in `databases/dr-drill.yaml` to v{N}, push before the apply. Never set
   `cnpg.io/skipEmptyWalArchiveCheck` (corrupts the source). PITR: `bootstrap.recovery.recoveryTarget.targetTime`
   before the apply, removed after. Recovery jobs fail until ESO delivers the S3 secret and the
   s3-gateway answers on `s3.unorouter.com` (CoreDNS rewrite, monitoring app); the jobs also need
   the `cnpg-jobs` policy in `infra/databases/networkpolicies.yaml`, applied by hand.
3. **Restore OpenBao**: `./scripts/dr.sh restore` (temp init, snapshot from the plain
   `openbao-snapshots/latest.snap` using only `tofu/.env`, restart, unseal, ESO restart). Then
   `tsh login` again, the Teleport CA is new. Age key lost: unseal keys are in Bitwarden,
   `dr.sh unseal` by hand.
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
     `tctl auth export --type=db-client` (own CA first, `ca.key` stays SEC1), then the agent
     identity: scale `teleport-app-access` to 0, delete `teleport-app-access-0-state`, scale to 1.
   - `kubectl -n dex rollout restart deploy/dex` and the same for cloudflared after any hostname
     change; both read config at boot.
   - Kubernetes auth in OpenBao and Velero's first sync self heal; restart ESO if it cached a
     failure, clear the Velero operation and refresh.
5. **Done when** the platform apps are Synced and the three app repos reappear as Applications
   (`kubectl -n argocd get app`), both CNPG clusters are healthy with WAL replay, services answer
   200 through the tunnel and SSO works. Verified twice on 2026-07-22 with zero manual auth steps.

## Node swap (executed four times, zero downtime)

Drive it from `./scripts/dr.sh kubeconfig`: the Teleport context routes through the in-cluster
apiserver Service, which loses endpoints mid-swap.

0. **A sniped spare** (`bootstrap/k0s/hetzner-snipe.sh`) has no cloud-init, so replay
   `tofu/cloud-init-join.yaml.tftpl` by hand: the 4G swapfile with `vm.swappiness=10`, the
   `coredns.yaml.skip` marker, Tailscale with `--ssh --accept-dns=false`, the tailnet address in
   `tls-san` of `/etc/rancher/k3s/config.yaml`, then k3s with the template's exact
   `INSTALL_K3S_EXEC` flags and the fleet's `INSTALL_K3S_VERSION`. Hetzner hands out the lowest
   free 10.100.1.x, keep it.
1. **Preflight**: primaries known, ArgoCD green, WAL archiving true, the old node's data fits
   the new disk.
2. **Join first**: the spare becomes the fourth etcd member, quorum never dips. Wait for 4 Ready,
   `/readyz/etcd` ok and cilium-health 4/4 from both the old and the new agent (about two minutes).
3. **Evacuate**: cordon, evict singletons one at a time as `kubectl delete pod` with a Ready
   check between (new-api master, bot, cilium-operator, teleport-app-access-0), then
   `drain --ignore-daemonsets --delete-emptydir-data`.
4. **Postgres replicas** stay Pending on node-pinned PVCs: delete PVC and pod, CNPG re-clones
   from the primary, one cluster at a time (3/3 then 2/2, one to six minutes each). Monitoring
   PVCs on the old node: delete them, or rsync the immutable TSDB block dirs into the new PV first.
5. **Remove**: `systemctl disable --now k3s` on the old node, `kubectl delete node`, then
   `tofu plan -destroy -target=hcloud_server.nodeX -out=f`, read it (exactly one destroy),
   `tofu apply f`.
6. **Import**: add the node.tf block (hardcoded type, `ignore_changes [user_data, ssh_keys]`),
   `tofu import`, apply the in-place reconcile (expect `+ network`, abort on any replace), final
   plan is No changes. Update the etcd target list in `infra/monitoring/extras/scrape/etcd.yaml`
   in the same commit or the etcd alerts go blind.

## Quorum loss

Two of three members gone: apiserver down, CNPG cannot promote, public reads keep serving.

1. Stop and disable k3s on every other node first; their join storm destabilises a fresh
   single-member etcd ("too many learner members").
2. On the survivor, under `nohup`: `k3s server --cluster-reset` with the same `--node-ip` and
   `--advertise-address` as the service unit, or membership is written with the public peer URL
   and k3s wedges on "not a member of the etcd cluster".
3. Rejoin nodes one at a time after `rm -rf /var/lib/rancher/k3s/server/db`.

## No tailnet

1. Hetzner Cloud Firewall: temporary inbound 22 for your current IP, SSH with the operator key,
   remove the rule.
2. Hetzner VNC console: needs the node root password (Bitwarden); keys do not work on a TTY.
3. Hetzner rescue mode boots with your key, mount the disk, repair.

Joining a rebuilt node to the tailnet: `tailscale up --auth-key=<OpenBao secret/tailscale
node_auth_key> --ssh --accept-dns=false --hostname=<name>`. The keys expire 2026-12-02; mint
tagged, reusable, pre-authorised ones in the admin console.
