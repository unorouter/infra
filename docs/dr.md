# Disaster Recovery runbook

Three Talos control planes with embedded etcd on the WireGuard mesh `10.200.0.0/24` (node11
.11, node12 .12, node13 .13). Public IPs are not in git: `./scripts/dr.sh ips` asks the Hetzner
API with only the token, so it works with no state, no S3 and no cluster. Every node is on the tailnet
(`tailscale` extension in the machine config); Talos has no sshd and no shell by design, so
`talosctl` over the tailnet with the rendered talosconfig is the whole management path.
Rendering needs git plus the break-glass age key (`talos/README.md`). Access paths in [access.md](access.md), node lifecycle in
[../talos/README.md](../talos/README.md).

Stateful placement: Prometheus, Alertmanager, Grafana and Loki on node12 (label
`unorouter.com/monitoring`); OpenBao, ArgoCD and Teleport wherever their PV landed; CNPG
newapi-pg 3 instances and bot-pg 2 on local-path PVs. Losing a node loses those PVs.

## Rules that hold in every scenario

- One node per tofu apply, plan read, exactly one destroy. A both-nodes `-replace` cost 34 min
  of database writes on 2026-07-23.
- `kubectl -n databases get cluster` for the primaries before any node surgery. A raw
  `status.targetPrimary` patch is never the tool (`kubectl cnpg reload` was, 2026-09-02).
- Memory limits only on the revenue services, none on Postgres, Prometheus, etcd and the
  platform. Nodes carry 4 GiB host swap that pods cannot use (`failSwapOn: false`, kubelet
  `NoSwap`).
- Liveness probes are `tcpSocket` only; killing a pod never fixes a slow dependency.
- Node names are cattle: the next number in `talconfig.yaml`, never reused.
- Never `talosctl edit mc`: edit `talos/patches`, render, `apply-config`. Never render before
  the patches carry every live setting.

## Backups

Everything is on Hetzner Object Storage (fsn1), which has no at-rest encryption, so the in-cluster
s3-gateway (`infra/monitoring/extras/s3-gateway.yaml`, `s3.unorouter.com` via CoreDNS rewrite)
encrypts client side with rclone crypt: content only, names in clear, the ciphertext copies to
any provider as is. Key: OpenBao `secret/backup-encryption` (`crypt_password`, `crypt_salt`),
break-glass copy in `secrets/break-glass.sops.yaml` (`backup_encryption`). Lose the pair, lose every object.

### Buckets (`tofu/buckets.tf`)

- `unorouter-backups`: Object Lock COMPLIANCE 30 d. `unorouter-logs`: COMPLIANCE 90 d. Nothing
  deletes, the lifecycle expires (set by signed PUT, the aws provider hangs on lifecycle PUT
  against RadosGW). No barman `retentionPolicy`. After a bucket change Hetzner frontends may
  briefly write objects without retention or answer `NoSuchBucket`: sweep and stamp.
- `unorouter-loki`: unlocked and unversioned on purpose, the compactor deletes and rewrites.
  Retention is Loki's 90 d (`infra/loki/values-loki.yaml`); the 120 d lifecycle only catches a
  dead compactor.
- `unorouter-velero`: unlocked (Kopia must delete and rewrite, velero-io/velero#8686), versioning
  is its protection. Velero backs up no Secrets (ESO, cert-manager and CNPG recreate them, the
  canaries and pg-s3 pairs have `secrets/k8s.sops.yaml`) and only PVs annotated
  `backup.velero.io/backup-volumes` (Teleport auth data, Grafana storage). Restoring one
  claim (2026-09-16): pause `automated` on `root` and the owning app first, or ArgoCD prunes
  the restored claim within seconds (it carries the tracking annotation); include
  `persistentvolumes` in `includedResources` or the claim keeps its dead `volumeName`; never
  pre-create the claim, Velero then skips the data. Strip the tracking annotation from the
  restored claim before sync resumes. An identity change on the auth server needs a fresh
  `tsh login` and the agent state Secret deleted.
- `unorouter-logs` is written by Vector under `vector/<source>/node=<node>/date=<day>/`, gzip
  ndjson, never overwritten.

### Rules

- Gateway: one auth pair for every in-cluster writer (`secret/s3gw`), network policy is the
  boundary. Uploads stage in a per pod write cache and reach Hetzner up to a minute after the
  writer's 200; a restart in that window loses the object. rclone 1.75+ only.
- CNPG serverName pair: `v7` is archive-to and, read only at bootstrap, the restore-from entry.
  On a DR create bump archive-to to `v8`; the pair must differ at create time. Switching the
  archive store drops every `Backup` CR: take a base backup right after.
- Key rotation: new `crypt_password` and `crypt_salt`, `bao kv patch`, ESO restart, gateway
  rollout, CNPG serverName bump and base backup, new sops file. Old objects stay readable with the
  old pair until the lifecycle expires them (31 d). Objects from before 2026-09-09 (`*-pg-v5`,
  `*-pg-v6`, `unorouter-evidence`) are unreadable noise until 2026-10-09; plaintext copies of
  everything as of that date are under `~/backups/` on the operator machine (LUKS, not synced).
- Restore drill: `infra/databases/dr-drill.yaml` restores bot-pg into a scratch cluster on the 1st of
  each month and counts populated tables; `DRDrillStale` warns after 35 d. By hand:
  `kubectl -n databases create job --from=cronjob/dr-drill dr-drill-manual`.
- `kubectl -n velero get backup` hits CNPG's CRD; use `get backup.velero.io`.
- After patching an S3 credential, restart every consumer that reads it as env once the
  ExternalSecret synced.
- `tsh play <session>` needs `ListObjectVersions`, which the gateway does not serve. Recordings
  are logs: download the tar, `tsh play --format=json <file>`.

### Download and decrypt drill (quarterly)

From a laptop with `tofu/.env` and the break-glass age key:

```bash
export RCLONE_CONFIG_HZ_TYPE=s3 RCLONE_CONFIG_HZ_PROVIDER=Ceph RCLONE_CONFIG_HZ_REGION=fsn1 \
  RCLONE_CONFIG_HZ_ENDPOINT=https://fsn1.your-objectstorage.com RCLONE_CONFIG_HZ_NO_CHECK_BUCKET=true \
  RCLONE_CONFIG_HZ_ACCESS_KEY_ID=... RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY=... \
  RCLONE_CONFIG_CR_TYPE=crypt RCLONE_CONFIG_CR_REMOTE=hz: RCLONE_CONFIG_CR_FILENAME_ENCRYPTION=off \
  RCLONE_CONFIG_CR_DIRECTORY_NAME_ENCRYPTION=false RCLONE_CONFIG_CR_SUFFIX=none \
  RCLONE_CONFIG_CR_PASSWORD=$(rclone obscure "$(sops -d --extract '["backup_encryption"]["crypt_password"]' secrets/break-glass.sops.yaml)") \
  RCLONE_CONFIG_CR_PASSWORD2=$(rclone obscure "$(sops -d --extract '["backup_encryption"]["crypt_salt"]' secrets/break-glass.sops.yaml)")
rclone copy cr:unorouter-backups/newapi-pg-v7/base/<latest>/ ./nb/ && tar -tzf ./nb/data.tar.gz | head   # PG_VERSION, base/
rclone cat hz:unorouter-backups/newapi-pg-v7/base/<latest>/backup.info | head -c 32 | xxd              # ciphertext
rclone copy cr:unorouter-logs/vector/k8s-audit/node=<node>/date=<day>/<obj>.ndjson.gz ./ && zcat ./<obj>.ndjson.gz | head -1 | python3 -m json.tool
rclone copy cr:unorouter-logs/teleport-recordings/<sid>.tar ./ && tsh play --format=json ./<sid>.tar | head -c 300
rclone copy hz:unorouter-velero/velero/backups/<latest>/ ./vb/ && tar -tzf ./vb/<latest>.tar.gz | grep -c secrets/   # 0
rclone copyto hz:unorouter-backups/openbao-snapshots/latest.snap ./latest.snap && gzip -t ./latest.snap
```

Every `cr:` GET repeated through `hz:` must be ciphertext. Cluster side: restore the postgres
base backup into a scratch cluster through the gateway (`bootstrap.recovery` from
`externalClusters` with the `-hz` ObjectStore, no `plugins` block so it never archives). The
gateway admits only the production cluster labels, so the scratch cluster needs a temporary
ingress rule in `s3-gateway` for its `cnpg.io/cluster` label, and a node with twice the database
in free disk (`local-path` does not enforce it).

## Rebuild from total loss

**Survives**: the buckets (`prevent_destroy`, so `dr.sh destroy` targets the nodes only), the
Talos snapshot on Hetzner (`talos/README.md` rebuilds it), git and its sops files, the
break-glass age key (VeraCrypt plus Bitwarden), Cloudflare DNS, the tunnel token in the vault
snapshot. **Dies**: nodes, etcd, every local-path PV (PGDATA, OpenBao raft, Teleport SQLite,
ArgoCD, monitoring), every pod.

0. **Pre-destroy on a live cluster**: writers to 0 (new-api master and slaves, bot, unorouter,
   mcp, uno-import), sync and archive CronJobs suspended, `SELECT pg_switch_wal()` and confirm
   the segment archived, a fresh OpenBao snapshot
   (`kubectl -n openbao create job --from=cronjob/openbao-raft-snapshot ...`), the lineage bump
   (step 2) pushed, then destroy. Skipping the WAL flush loses the last five minutes.
1. **Recreate**: `./scripts/dr.sh talosconfig`, `./scripts/dr.sh apply` (servers boot the
   snapshot with their config as user data), `./scripts/dr.sh bootstrap` (`talosctl bootstrap`
   on the first node, Cilium, ArgoCD, root app). Hand-applied objects no Application owns:
   `apps/appproject-apps.yaml`, `apps/appset-services.yaml`.
2. **Bump the CNPG lineage**, the one unavoidable edit: CNPG halts a restored primary that
   archives to the path it restored from. In the app repos (`unorouter/new-api`,
   `unorouter/unorouter-bot`, `k8s/pg.yaml`): `plugins[].serverName` to v{N+1},
   `externalClusters[<x>-origin].serverName` to v{N} (v8 since 2026-09-12), drop the `replica`
   block, `LINEAGE` in `infra/databases/dr-drill.yaml` to v{N}, push before the apply. Never set
   `cnpg.io/skipEmptyWalArchiveCheck` (corrupts the source). PITR:
   `bootstrap.recovery.recoveryTarget.targetTime` before the apply, removed after. Recovery jobs
   fail until ESO delivers the S3 secret and the s3-gateway answers (monitoring app), and need
   the `cnpg-jobs` policy. A joining replica needs the current timeline's history file in the
   archive (`0000001C.history` had to be copied from the primary's `pg_wal` once).
3. **Restore OpenBao**: `./scripts/dr.sh restore` (temp init, `openbao-snapshots/latest.snap`
   with the `pg-s3` pair from sops, restart). A sealed pod is never Ready, so finish with
   `./scripts/dr.sh unseal`, `kubectl -n external-secrets rollout restart deploy/external-secrets`,
   force-sync every ExternalSecret, `tsh login` again (new Teleport CA). Age key lost: unseal
   keys are in Bitwarden.
4. **Hand steps git does not carry**:
   - `psql -U postgres -d newapi -f infra/databases/quota-audit.sql`,
     `reader-least-privilege.sql` and `ip-retention-least-privilege.sql` after a cluster built
     from `initdb` (a physical restore keeps
     roles, triggers and RLS; an initdb cluster lets `reader` read every PAT and password hash).
   - OpenBao OIDC role is a runtime write, every field:
     ```sh
     bao write auth/oidc/role/admin \
       allowed_redirect_uris='https://openbao.unorouter.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback' \
       user_claim=email token_policies=admin bound_audiences=openbao \
       oidc_scopes=openid,profile,email,groups groups_claim=groups \
       token_ttl=168h token_max_ttl=768h
     ```
     and `bao auth tune -listing-visibility=unauth oidc/`.
   - Teleport is stateless: reapply `infra/teleport/resources/*.yaml` (connector secret from
     OpenBao `teleport-github`), rebuild the `newapi-pg-client-ca` bundle with a fresh
     `tctl auth export --type=db-client` (own client CA first, `ca.key` stays SEC1), then the
     agent identity: scale `teleport-app-access` to 0, delete `teleport-app-access-0-state`,
     scale to 1.
   - `rollout restart` dex and cloudflared after any hostname change; both read config at boot.
   - The edge rule "machine surface ... own nodes" lists the node public addresses
     (`infra/cloudflare/unorouter.com/rules*.sops.yaml`); new nodes sit in a datacenter ASN the
     challenge rule targets, so in-cluster probes fail until the set is updated and applied.
   - Kubernetes auth in OpenBao and Velero's first sync self heal; restart ESO if it cached a
     failure, clear the Velero operation and refresh.
5. **Done when** the platform apps are Synced and the app repos reappear as Applications, both
   CNPG clusters are healthy with WAL replay, services answer 200 through the tunnel, blackbox
   probes pass, SSO works.

## Encrypted volumes

`EPHEMERAL`, swap and the local-path volume are LUKS2 with a key derived from the VM UUID
(`docs/operations.md` "Encryption at rest"). A Hetzner snapshot booted on another server, a
rescue-mode copy or a pulled disk is refused with `encryption key rejected` and the node
stays in maintenance; that is the intended outcome, not a fault. Recovery of such a node is
the normal path: fresh server, config as user data, etcd from the snapshot bucket, CNPG from
WAL. A Hetzner rebuild or resize of the same server keeps the UUID and unlocks.

## Node swap (zero downtime)

Drive it from `./scripts/dr.sh kubeconfig`: the Teleport context routes through the in-cluster
apiserver Service, which loses endpoints mid-swap.

0. The new node boots with its rendered config as user data, by tofu or by the sniper
   (`scripts/hetzner-snipe.sh`, `SNIPE_USER_DATA`): "A new node" in `talos/README.md`.
1. Preflight: primaries known, ArgoCD green, WAL archiving true, the old node's data fits.
2. Join first: the new node becomes the fourth etcd member, quorum never dips. Wait for 4 Ready,
   `talosctl -n <new> etcd status`, cilium-health 4/4 (about three minutes).
3. Evacuate: cordon, evict singletons one at a time with a Ready check between (new-api master,
   bot, cilium-operator, teleport-app-access-0), then `drain --ignore-daemonsets
   --delete-emptydir-data`.
4. Postgres replicas stay Pending on node-pinned PVCs: delete PVC and pod, CNPG re-clones from
   the primary, one cluster at a time. Monitoring PVCs on the old node: delete them, or rsync
   the immutable TSDB block dirs into the new PV first.
5. Remove: `talosctl -n <old> reset` (graceful, leaves etcd itself), `kubectl delete node`,
   `tofu plan -destroy -target='hcloud_server.node["<old>"]' -out=f`, read it (exactly one
   destroy), `tofu apply f`. `talosctl etcd remove-member` only for a node that is already gone.
6. Import: the node in `local.nodes` (`tofu/nodes.tf`), `tofu import
   'hcloud_server.node["<node>"]' <id>`, final plan No changes. The SANs in `talconfig.yaml` and
   the own-nodes edge rule in the same change, or probes go blind.

## Quorum loss

Two of three members gone: apiserver down, CNPG cannot promote, public reads keep serving.
Nightly etcd snapshots are in `unorouter-backups/etcd/<node>/` (`infra/talos/etcd-backup.yaml`).

1. `talosctl -n <dead or rejoining> reset --graceful=false` so they do not fight the recovery.
2. On the survivor: `talosctl -n <node> bootstrap --recover-from <snapshot>
   --recover-skip-hash-check` after fetching the newest snapshot through the crypt gateway.
3. Rejoin the others one at a time. Proven twice on the spares on 2026-09-10.

## No tailnet

Two rules to open, both temporary: inbound 50000 for your IP in the Hetzner Cloud Firewall and
the same in `talos/patches/firewall.yaml` (`tailnet` rule, needs a render and apply through a
node that is still reachable). No node reachable at all: rescue mode, mount the STATE
partition, set `NetworkDefaultActionConfig` `ingress: accept` in the config, reboot. Then
`talosctl -e <public ip>`, remove both rules. Port 22 does not exist. The Hetzner console shows the Talos dashboard, no login;
rescue mode boots with the operator key and can mount the disk. A rebuilt node joins the tailnet
from its machine config (`tailscale` extension, `TS_AUTHKEY` in `talos/talenv.sops.yaml`,
pre-signed for Tailnet Lock).

## Cluster switchover (executed 2026-09-12, k3s to Talos)

The template for a move between clusters or datacenters: both databases ran as CNPG replica
clusters on the new site, restored from the old archive and streaming from the old primaries,
with distributed topology names `<x>-origin` and `<x>-talos` on both sides.

1. New site ready: vault restored from a fresh snapshot, own tunnel with shadow hostnames,
   images pulled, AppProject and SCM secret present, replicas at sub-second lag.
2. Freeze writers on the old site (apps to 0, crons suspended, old ArgoCD controller to 0).
3. Demote on the old site: `kubectl -n databases patch cluster <x> --type=merge -p
   '{"spec":{"replica":{"primary":"<x>-talos"}}}'`; CNPG fences, archives the shutdown
   checkpoint and writes `status.demotionToken` (nine seconds).
4. Promote on the new site with both fields in one patch:
   `{"spec":{"replica":{"primary":"<x>-talos","promotionToken":"<token>"}}}`. A token-less flip
   is a failover and rebuilds the old site.
5. Push the post-switch manifests, smoke the shadow hostnames, move the wildcard and apex CNAMEs.
   The edge keeps sending traffic to the old tunnel for about three minutes.
6. The old site follows as a replica; rollback is the same token exchange in reverse.

Write outage 72 s, user-facing errors about four and a half minutes. Needed from the start next
time: own-nodes edge rule, metrics-server, ArgoCD PodMonitor by port number, the uno-import
namespace.
