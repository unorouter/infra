# Disaster Recovery runbook

## TOPOLOGY SINCE 2026-07-23: 3-node etcd HA (multi-DC)

- node1 cx33 fsn1 (116.202.14.228, 10.100.1.1) + node4 cx23 hel1 (89.167.21.83,
  10.100.1.4) + node5 cx23 nbg1 (178.104.78.126, 10.100.1.3). All k3s SERVERS, embedded
  etcd -- quorum survives a full DC outage. Private net 10.100.0.0/16 carries
  etcd/vxlan/apiserver-kubelet (all servers run `--advertise-address=<private>`; without
  it remotedialer dials public :6443 = firewalled). (Interim cpx22 node2/node3 retired
  2026-07-23 via sniped-swap procedure below; node numbering is cattle -- k3s node names
  are baked at registration, so replacements get the next number instead of reusing the
  old one. COST MISSION COMPLETE: servers EUR19.47/mo, tofu var ha_node_type removed.)
- k3s join token: `tofu/.env` TF_VAR_k3s_token + OpenBao `secret/cluster.k3s_join_token`.
- Cilium `k8sServiceHost: 127.0.0.1` is VALID only because every node is a server. Adding
  an AGENT node requires changing that first. After changing any node's --node-ip, restart
  the cilium daemonset (agents cache node IPs; stale public IP breaks cross-node vxlan
  through the firewall).
- CNPG: newapi-pg instances 3 (one per DC), bot-pg 2. spec.instances is GIT-owned (the old
  ignoreDifferences entry deliberately removed).
- Still node1-affine (local-path PVs / fixed IP): openbao, teleport (+grey-cloud DNS),
  argocd, redis, mcp, new-api-master. Node1 loss = those restart cold on another node
  minus their PVs -> follow the DR restore path for openbao; teleport is stateless-by-design.
### Cluster access hierarchy (kubectl)

1. **Teleport (primary, audited)**: `tsh login --proxy=teleport.unorouter.com --auth=github`
   -> `tsh kube login unorouter` -> kubectl. Session-recorded, SSO, short-lived certs.
   Context `teleport.unorouter.com-unorouter`. Set up 2026-07-23: the agent runs
   `roles: app,db,kube` + `kubeClusterName: unorouter` (registers the kube_cluster), the
   `kube-admin` Teleport role grants `kubernetes_groups: [system:masters]`, mapped to the
   GH `unorouter/admins` team in the connector. Role/connector applied via tctl (connector
   needs the client_secret from OpenBao `secret/teleport-github`); values.yaml is git/ArgoCD.
   GOTCHA: a `tsh login` reusing a still-valid cert keeps the OLD roles -- after any
   connector role change, `tsh logout` THEN login to re-map (else kube-admin is absent).
2. **Direct kubeconfig (backup)**: `kubectl --context unorouter-direct ...` (hits node1
   apiserver at :6443 directly, in `~/.kube/config`). Use when Teleport is down. Also
   `infra/kubeconfig` in the repo as a portable copy.
3. **Raw SSH (break-glass)**: `ssh root@<node-public-ip>` -- for the layer BELOW k8s
   (etcd/quorum recovery, k3s install/stop, node disk/journal) when the kube API itself
   is dead. IPs in `tofu` outputs.

- DRILLS PASSED 2026-07-23: node3 drain (30/30 public probes 200), newapi-pg primary kill
  (promotion ~70s, 25/25 probes 200, old primary auto-rejoined as replica).

### INCIDENT 2026-07-23 ~13:19-13:53 CEST: quorum loss + 34min DB-write outage (self-inflicted)

Trigger: interim node-type downswap executed with `TF_VAR_ha_node_type=cpx22 tofu apply
-replace=hcloud_server.node2`. The env override changed BOTH nodes' server_type, so the plan
replaced node2 AND node3 -- node3 was destroyed UNDRAINED. The pg primary lived on node2
(post-drill) and etcd lost 2 of 3 members simultaneously: quorum gone, apiserver down, CNPG
unable to promote the surviving replica -> "Database error" for all logins/writes ~34min.
Public reads/pages kept serving off node1 the whole time (data plane independent). ZERO data
loss (replica was current; S3 PITR untouched).

RULES (cost of learning them: 34min of revenue downtime):
1. NEVER combine a var override that widens blast radius with -replace + -auto-approve.
   ALWAYS `tofu plan` first and READ the add/change/destroy lines before any apply that
   touches servers. One node at a time means the PLAN must show exactly one destroy.
2. k3s quorum-loss recovery: `k3s server --cluster-reset` on the survivor -- MUST pass the
   SAME --node-ip/--advertise-address flags as the service unit, or membership is written
   with the PUBLIC peer URL and k3s wedges on "not a member of the etcd cluster" (the fix
   attempt itself failed twice on this). Run it under nohup (a killed ssh mid-reset leaves
   a broken half-state + reset-flag). Stop/disable k3s on all OTHER nodes first (their
   join storm destabilizes the fresh single-member etcd: "too many learner members").
3. Rejoin nodes ONE at a time with `rm -rf /var/lib/rancher/k3s/server/db` first.
4. Replicas whose local-path PVCs lived on dead nodes: delete pod + PVC, CNPG re-provisions
   from the primary automatically (~4min for 1GB).
5. Before ANY node surgery: check where the CNPG primaries currently run
   (`kubectl get cluster -n databases`) -- drills move them; assumptions rot in hours.

Current HA nodes after incident: 2x cpx22 (4GB, EUR19.49 -- overpriced AMD, only stock).
Target stays 2x cx22 (EUR4.49) when Intel returns; swap MANUALLY with plan-review, one node
per apply, primaries checked first.

### SWAP EXECUTED 2026-07-23 ~14:55-15:20: node3 cpx22 -> node4 cx23 (zero downtime)

Sniper (`scripts/hetzner-snipe.sh`) grabbed a cx23 (EUR5.49) during a ~1min hel1 stock
window; hand-incorporated per the rules above. This is the CANONICAL single-node swap:

1. Preflight: both CNPG primaries confirmed on node1 (rule 5), argocd 14/14 green, WAL
   archiving True on both clusters, old node's disk usage fits the new type, ssh to spare ok.
2. JOIN-FIRST: spare renamed unorouter-node4 (API + hostnamectl), k3s server installed with
   the exact cloud-init-join flags (token from tofu/.env; pin INSTALL_K3S_VERSION to the
   fleet version) -> 4th etcd member. Quorum never dips below tolerate-1 at any point.
   Verify BEFORE proceeding: 4 Ready, /readyz/etcd ok, journalctl tunnels to 10.100.x,
   cilium-health 4/4 from node1's AND the new node's agent (probe cycle ~2min, wait it out).
3. Drain old node (cordon+drain); its pg replica PVCs are local-path-pinned -> pods go
   Pending: delete PVC + pod, CNPG rebuilds replicas on the new node (~6min). Wait 3/3+2/2.
4. Remove: systemctl stop+disable k3s on old node FIRST, kubectl delete node, then
   `tofu plan -destroy -target=hcloud_server.nodeX -out=f` -- READ (exactly 1 destroy) --
   `tofu apply f`. Plan-file apply = the reviewed plan is the executed plan.
5. Import: node.tf block for the new node (hardcoded server_type, lifecycle ignore_changes
   [user_data, ssh_keys] -- hand-built server, template is DR-rebuild-only),
   `tofu import`, then apply the small in-place reconcile (import does NOT capture the
   inline network block or provider booleans -- expect `+ network` as update-in-place;
   abort if the plan says replace/destroy). Final `tofu plan` = No changes.

Note: nodes reach each other over the private net (10.100.x); node SSH is public-IP + firewall
(port 22). Tailscale is not used on the current fleet -- it's a future/optional overlay only.

Node2 swap (same day, ~16:10-16:30, -> node5): identical procedure, ONE delta -- node2
carried singletons (new-api-master, unorouter-bot, cilium-operator). After cordon, evict
singletons FIRST as individual `kubectl delete pod` (reschedule elsewhere, wait Ready +
endpoint 200 between each), THEN drain the rest. Master reschedule was seconds (slaves keep
serving); bot = one Discord gateway reconnect, deploy-grade. Also: Hetzner recycled the
destroyed node3's private IP (10.100.1.3) for the new spare -- auto-assigned IPs reuse the
lowest free address, harmless, keep whatever the spare got.


Full node loss -> back online with the smallest manual intervention. The node is disposable
cattle; all durable state lives OFF-node (Hetzner S3, git, SOPS-in-git, age key, Bitwarden,
Cloudflare DNS).

## What survives `tofu destroy`

- **Hetzner S3** (`unorouter-pg-backups`, `prevent_destroy`): CNPG base backups + WAL (PITR),
  Vault raft snapshots, tofu remote state.
- **git** (this repo): every manifest + the ArgoCD app-of-apps.
- **SOPS secrets in git**: Vault unseal keys + root token, tofu creds (decrypt with the age key).
- **age private key**: offline on the operator laptop (`~/.config/sops/age/keys.txt`).
- **Bitwarden**: second copy of the Vault unseal key (break-glass if the age key is lost).
- **Cloudflare DNS**: records point at the node IP; only edit if the new node IP differs.

## What dies (all restorable from the above)

The CAX31 node + disk, k3s + etcd, ALL local-path PVs (CNPG PGDATA, Vault raft, Teleport
SQLite, ArgoCD), every pod.

## 3-NODE DR NOTES (2026-07-23 audit; template fixes committed, NOT live-tested -- the
## single-node flow was tested twice, the 3-node deltas below are paper-verified)

- `tofu apply` now creates all THREE nodes. node1's cloud-init self-initializes etcd
  (`--cluster-init --token <fixed> --node-ip/--advertise-address 10.100.1.1`); node2/3 join
  via the fixed token (TF_VAR_k3s_token in tofu/.env + OpenBao secret/cluster). Joiners
  retry until node1's apiserver is up -- a few minutes of join errors at boot are normal.
- node1 has `lifecycle.ignore_changes[user_data]`: template edits NEVER replace the live
  node; they apply on genuine rebuild only.
- CNPG `instances: 3` + `bootstrap.recovery`: restores the primary from S3 first, then
  builds both replicas from it automatically. Same lineage-bump rule as before.
- New IPs after rebuild: teleport externalIPs + grey-cloud A record need ONLY node1's IP.
  node2/3 IPs matter to nothing external (tunnel is outbound).
- PRE-DESTROY additions for a LIVE cluster (unlike the don-era tests, k3s now serves
  production): scale writers to 0 (new-api master+slaves, bot), `SELECT pg_switch_wal()`
  + verify the segment archived, force a fresh OpenBao snapshot, THEN destroy. Skipping
  the WAL flush loses the last <=5min of writes.

## The 3 steps

### 1. Recreate the node (ZERO-TOUCH bootstrap)

```
make apply       # tofu apply -> fresh node; cloud-init auto-deploys Cilium+ArgoCD+root-app
```

VERIFIED (2026-07-22, 2nd destroy test): cloud-init writes k3s auto-deploy manifests
(`/var/lib/rancher/k3s/server/manifests/`): Cilium HelmChart (`bootstrap:true` -> installs
before CNI-ready, node goes Ready), ArgoCD helm chart, and the root app-of-apps. So
`tofu apply` ALONE brings up k3s + Cilium + ArgoCD + the whole app-of-apps from git. NO
`make bootstrap` needed (that target remains as a manual fallback only). ArgoCD then
reconciles cert-manager, CNPG operator, OpenBao, ESO, databases. CNPG `Cluster`s come up
(initdb; flip to `bootstrap.recovery` from S3 once cut over from don). OpenBao boots SEALED +
UNINITIALIZED (fresh raft).

Note: on a rebuilt node reusing the old IP, clear the stale SSH host key first:
`ssh-keygen -R <node-ip>`.

If the new node IP differs from the old, update the Cloudflare A records (grey-cloud for
`teleport.unorouter.com`; proxied for the rest) and the firewall `operator_cidr` if yours changed.

### 2. Bump the CNPG serverName lineage (the ONE unavoidable edit)

CNPG's empty-archive safety check HALTS the restored primary if it archives WAL to the same
S3 path it restored FROM. So on every DR event, bump BOTH serverNames by one:

- `databases/newapi-pg/cluster.yaml`: `externalClusters[].serverName` v{N} -> v{N+1},
  `plugins[].serverName` v{N+1} -> v{N+2}.
- Same for `databases/bot-pg/cluster.yaml`.

Commit + push. ArgoCD picks it up; the restore reads the old lineage, new WAL archives to the
fresh lineage. Do NOT set `cnpg.io/skipEmptyWalArchiveCheck` (that corrupts the source).

Verify restore:

```
kubectl -n databases get cluster newapi-pg bot-pg   # wait for status: Cluster in healthy state
```

### 3. Restore OpenBao (fresh raft) -- VERIFIED SEQUENCE (2nd destroy test 2026-07-22)

A fresh OpenBao has empty raft. The restore is now ONE command (temp-init -> restore snapshot
-> restart pod -> unseal with original keys -> ESO resync, all automated):

```
make restore          # == ./scripts/dr.sh restore
```

Then: `tsh login --proxy=teleport.unorouter.com` (Teleport CA regenerated -> re-login).

Break-glass (age key lost): unseal keys are in Bitwarden -> `bao operator unseal` by hand.

OIDC gotchas (found 2026-07-23 during the ops-subdomain rename; both bit because they are
NOT reconciled from git):
- **Dex loads config only at boot -- no hot-reload.** After ANY change to `dex-config`
  (e.g. a redirect-URI rename), `kubectl -n dex rollout restart deploy/dex` or logins fail
  with "Bad Request: Unregistered redirect_uri". The configmap can look correct while the
  running Dex serves the old one.
- **OpenBao's OIDC role redirect is a runtime `bao write`, not a manifest.** On DR (fresh
  raft) or any hostname change, re-set it:
  `bao write auth/oidc/role/admin allowed_redirect_uris='https://openbao.unorouter.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback'`
  (plus user_claim=email, token_policies=admin, bound_audiences=openbao, oidc_scopes=openid,profile,email,groups, groups_claim=groups, token_ttl=168h, token_max_ttl=768h). Dex must ALSO allow that callback (dex.yaml staticClients).
  Role writes REPLACE the whole role -- always send every field, a partial write wipes the rest.
  token_ttl=168h keeps the UI session alive a week (default 8h forced daily re-login); no
  auto-submit login exists in OpenBao, long sessions are what makes it feel like ArgoCD.
- **OpenBao UI defaults to the Token method** unless OIDC is surfaced:
  `bao auth tune -listing-visibility=unauth oidc/` makes OIDC the login default (re-apply on
  DR). OpenBao 2.6.0 has NO `sys/config/ui/login/default-auth` (Vault 1.20+ only), so this is
  the best available -- KNOWN caveat (vault#10816): after logout/expiry the UI snaps back to
  the Token tab. Bookmark `openbao.unorouter.com/ui/vault/auth?with=oidc%2F` to always land on
  OIDC. Login: method OIDC, role blank (default=admin), Sign In -> GitHub.

### DR test learnings (2026-07-22, all folded into the steps above)

1. Bucket is in its OWN tofu state (`tofu/storage/`) so `make destroy` (plain `tofu destroy`)
   physically cannot reach it -- no -target/-exclude needed. prevent_destroy guards storage/ too.
2. Vault pod MUST be restarted after `snapshot restore -force` or unseal fails.
3. k8s auth is now SELF-HEALING (kubernetes.default.svc host + omit token_reviewer_jwt/ca ->
   OpenBao reads its pod SA token/CA fresh each request). NO reconfigure after rebuild. Just
   restart ESO if it cached a failure. (VERIFIED 2nd test: ESO synced with zero manual auth steps.)
4. Cilium + ArgoCD now auto-deploy via cloud-init (zero-touch). `make bootstrap` = fallback only.
VERIFIED (x2): full destroy/apply recovered all 7 apps + an OpenBao DR-marker survived, with
zero-touch bootstrap and self-healing auth (2nd test needed NO make bootstrap, NO auth reconfigure).

## Notes

- The `options_masked` view + `reader` role + grants are schema objects -> they ride the
  physical S3 backup and come back on their own. No post-restore SQL. (First-ever migration
  from don applies `databases/newapi-pg/masking.sql` once; see P2.)
- Recover-to-latest is the default (no `recoveryTarget`). For PITR, set
  `bootstrap.recovery.recoveryTarget.targetTime` before the apply, then remove it after.
- TEST the full destroy/apply/restore cycle on a THROWAWAY cluster before trusting it on
  revenue (CNPG#6645 Hetzner-restore is a known sharp edge -- hard gate).

## Full-DR test findings (2026-07-22, destroy -> apply -> restore, PASSED)

Verified end to end: node rebuild (fsn1, new IP), zero-touch cloud-init bootstrap, 14 apps
reconciled, OpenBao snapshot restore + unseal, ESO resync, BOTH CNPG clusters restored from
S3 (base + WAL replay incl post-backup writes; users=8531 exact), services 200 via tunnel,
Dex SSO, Teleport App/DB access. Extra steps the happy path needs:

1. **Pre-destroy: force a fresh OpenBao snapshot** (`kubectl -n openbao create job
   --from=cronjob/openbao-raft-snapshot ...`). The 6h cron can be older than recent
   secret rotations; restoring a stale snapshot resurrects dead credentials.
2. **CNPG lineage bump**: restore-from = last archive lineage, archive-to = +1 (committed
   BEFORE destroy; bootstrap.recovery is create-time-only).
3. **New node IP**: update `infra/teleport/values.yaml` externalIPs + the grey-cloud
   `teleport.unorouter.com` A record. Tunnel-routed hosts follow automatically.
4. **Teleport is stateless by design (fresh SQLite)**: reapply
   `infra/teleport/resources/*.yaml` (github connector needs client_secret injected from
   OpenBao `teleport-github`); users `tsh login` again.
5. **Teleport db-client CA is regenerated** -> rebuild `newapi-pg-client-ca` bundle:
   own CA cert (first block, key unchanged in OpenBao) + fresh
   `tctl auth export --type=db-client`. ESO resyncs, cnpg.io/reload reloads postgres.
   NOTE: ca.key must be SEC1 ("BEGIN EC PRIVATE KEY"); CNPG rejects PKCS8.
6. **masking.sql** re-apply after any fresh don import (don has no RLS); after pure
   S3 recovery it rides the backup.
7. **Races that self-heal**: CNPG recovery jobs may fail until ESO delivers the S3
   secrets (operator retries); velero can deadlock its first sync waiting on the
   DaemonSet whose secret its own sync creates -- clear operation + refresh.
8. **Hetzner Ceph**: boto3>=1.36 checksum headers hang multipart base backups
   (AWS_*_CHECKSUM_*=when_required in Cluster.spec.env fixes; WAL unaffected).
   A healthy 1GB backup takes ~15 min and logs NOTHING at default level (-vv shows parts).

## Standing logical replication (don -> CNPG, pre-cutover)

don streams every write live into the k3s clusters (subscription `don_sync` on both DBs;
publications `k3s_pub` on don, `wal_level=logical`). Mirror lag is ~0; runs indefinitely.
k3s new-api is PARKED (replicas 0 in git) so nothing else writes the mirrored tables.
don is protected by `max_slot_wal_keep_size` (10GB newapi / 2GB bot): if k3s stalls longer
than the cap, the slot is invalidated (don unaffected) -- re-init = truncate mirror tables
(NOT secret_keys) + recreate the subscription with copy_data=true.

### CUTOVER EXECUTED 2026-07-23 ~01:05-01:15 CEST (procedure below kept for reference)

k3s is production now. don revenue containers are COLD (new-api scaled 0, bot stopped;
unorouter/mcp/redis/postgres still running but receive no traffic). DNS: specific records
api/www/status/bot/mcp + apex -> k3s tunnel; don wildcard remains for postiz/debug.
Rollback within ~1wk = revert those DNS records + rescale don services (data written on
k3s after cutover would be lost -- reverse-replicate first if >minutes of traffic).

Gotcha hit at cutover: bot reads ONLY `DATABASE_URL` (src/lib/db.ts), the POSTGRES_* parts
in bot-env are decoration -> added DATABASE_URL to OpenBao `secret/bot-env` pointing at
bot-pg-rw. Sequences setval'd from don, subscriptions dropped (slots removed on don too).

DON DECOMMISSIONED 2026-07-23 ~12:00: revenue containers REMOVED (new-api stack,
unorouter a/b, mcp, bot, both postgres + redis + pgbackup/logrotate sidecars). Public DB
ports 5439/5442 closed with them. Data volumes KEPT on don disk as cold archive (last
state = cutover + zombie writes; restore-of-last-resort via pg dump from the volume dirs).
postiz + debug-* + hobby stay. Rollback now = k3s DR path only (tested; S3 PITR).
Still open: rotate don sudo password, retire Duplicati source dirs for migrated DBs.

### Incident 2026-07-23 night: frontend crashloop ~8h (site 502, API unaffected)

Chain: k3s unorouter-env was missing `INTERNAL_API_URL` (don injects it via compose, not
.env -- same trap as bot's DATABASE_URL) -> frontend server-side calls fell back to public
`https://api.unorouter.com` (hairpin: pod -> CF edge -> tunnel -> back into cluster) ->
Cloudflare L3/4 auto-mitigation started dropping the node's IPv4 mid-TLS-handshake for our
zone only (v6 fine, other CF zones fine, external clients fine; invisible in zone security
events; zone IP-allow rule does NOT bypass it) -> /api/ops/health hung >5s -> liveness
probe (same dep-checking endpoint, 5s timeout) killed both replicas in a loop all night.

Fixes (all in git/OpenBao):
1. Liveness = tcpSocket ONLY (process-local); readiness keeps the dep check, 10s timeout.
   Killing a pod never fixes a slow external dep.
2. `INTERNAL_API_URL=http://new-api.services.svc.cluster.local:3000` in unorouter-env,
   `NEW_API_URL` same in bot-env: in-cluster server-side traffic NEVER leaves the cluster.
   Browser-facing NEXT_PUBLIC_API_URL stays public (external clients unaffected by design).
3. Node IP whitelisted in CF zone (L7 only, kept as belt).

Lesson: don compose files inject env vars beyond .env -- when migrating a service, diff
`docker inspect <c> .Config.Env` against the k8s secret, not just the .env file.
Lesson 2: no alerting = 8h silent frontend outage. healthchecks.io/ntfy is next.

Also 2026-07-23: don's new-api ZOMBIE-RESPAWNED ~40min after cutover -- a repo push
triggered the old "Docker Prod" workflow (self-hosted runner, `docker stack deploy`
restores compose replicas). Ran 11h in parallel (own stale DB, same provider keys ->
burned shared upstream rate limits). Fix: "Docker Prod" workflows DISABLED in all three
repos (new-api / unorouter-bot / unorouter); GHCR image builds stay active. k3s deploy
after image build = manual `kubectl rollout restart` for now (no image updater yet).

### Cutover procedure (minutes, not a freeze-window)
1. Stop don writers: `docker service scale newapi_newapi-master=0 newapi_newapi-slave=0`
   + stop don bot container.
2. Wait lag=0 (compare `count(*) FROM logs` both sides; it converges in seconds).
3. Sequences are NOT replicated: sync them --
   on mirror: `SELECT format('SELECT setval(%L, %s);', S.relname, last_value) ...`
   (script: for each sequence on don, `setval` same value on the mirror; both DBs).
4. Drop subscriptions: `DROP SUBSCRIPTION don_sync;` (both DBs).
5. Un-park k3s: restore replicas (master 1, slaves 2) in services/newapi.yaml, bot 1; push.
6. Flip DNS to the tunnel: api / unorouter+www+status / mcp / bot hostnames -> tunnel CNAME
   + add the hostnames to cloudflared ingress. Purge CF cache for unorouter.com.
7. Watch relay success + /api/status; don stays cold-intact for instant DNS rollback.
