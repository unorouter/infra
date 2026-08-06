# Disaster Recovery runbook

## Topology

node1 cx33 fsn1 (10.100.1.1) + node6 cx33 hel1 (10.100.1.2) + node7 cx33 nbg1 (10.100.1.4).
All k3s SERVERS, embedded etcd -- quorum survives a full DC outage. Private net 10.100.0.0/16
carries etcd/vxlan/apiserver-kubelet.

Public IPs are deliberately NOT in this repo (it is public). Get them with `./scripts/dr.sh ips`
-- it queries the Hetzner API with just `TF_VAR_hcloud_token`, so it works when tofu state, S3
and the cluster are all unavailable (`tofu output` needs all three). Hetzner console is the
fallback if the token is lost. Only node7's is externally discoverable anyway -- it is the
sacrificial Teleport entry node and its IP is the grey-cloud A record; node1's must stay
unpublished because it holds the pg primaries and OpenBao.

- Join token: `tofu/.env` TF_VAR_k3s_token + OpenBao `secret/cluster.k3s_join_token`.
- Cilium `k8sServiceHost: 127.0.0.1` is valid ONLY because every node is a server; adding an
  AGENT requires changing that first. After changing any `--node-ip`, restart the cilium
  daemonset (cached IPs break cross-node vxlan through the firewall).
- CNPG: newapi-pg 3 instances (one per DC), bot-pg 2. `spec.instances` is git-owned.
- **node1-affine** (local-path PVs): openbao, argocd, redis, mcp. Node1 loss = those restart
  cold minus their PVs -> OpenBao needs the restore path below.
- **node7-affine**: the monitoring stack. Swapping node7 = delete its 3 PVCs, lose metric
  history. No prod impact, rebuilds empty, not a blocker.
- Node numbering is cattle: k3s bakes names at registration, so replacements take the next
  number. node2/3 (cpx22) -> node4/5 (cx23) 2026-07-23; node4 -> node6 and node5 -> node7
  (cx33 8GB, same-DC) 2026-07-24 after the RAM-pressure incident. Fleet now uniform 8+8+8.

## Memory posture (limits + host swap)

Memory limits were set 2026-07-25 on the five revenue services (new-api master/slave,
unorouter, bot, mcp) at ~2-3x observed peak. That caps the ONE failure from 2026-07-23: a
single container growing unbounded until it OOM-starved the node.

It does NOT cover everything, and the difference matters:

- **~5.4Gi of pod memory is still uncapped** and mostly should be. Postgres (~850Mi/instance)
  and Prometheus (~730Mi) are deliberately cache-hungry; a hard cap makes Postgres thrash disk
  and puts Prometheus in an OOM-restart loop that loses data. ArgoCD, OpenBao, Cilium, Teleport
  and ESO are also unlimited.
- **k3s/etcd sits outside Kubernetes entirely** (~1.3Gi RSS, ~500Mi db). No k8s limit can touch
  it, and it is the process that actually caused the 2026-07-24 incident: memory pressure ->
  etcd fsync stall -> lease timeouts -> NodeNotReady flaps.
- **HOST-ONLY swap, 4Gi per node** (added 2026-07-25, `/swapfile`, `vm.swappiness=10`, in
  `/etc/fstab` + both cloud-init templates). This covers what limits cannot: multi-pod spikes,
  system/host processes, and reclaiming cold pages -- the node gets a soft landing instead of a
  hard OOM kill.
  **Pods never swap.** k3s runs `--kubelet-arg=fail-swap-on=false` while `swapBehavior` stays
  at its `NoSwap` default, so only host processes can use it. That is deliberate: these are
  control-plane/etcd nodes, and letting Postgres or etcd page to disk would trade a hard failure
  for unpredictable fsync latency -- the exact 2026-07-24 failure mode. Confirm after any k3s
  restart with `journalctl -u k3s | grep "NoSwap is set"`.
  swappiness=10 keeps it idle under normal load; `NodeMemoryFreeLow` (<400Mi) still alerts.

## Incident triage: CHECK GRAFANA FIRST

[grafana.unorouter.com](https://grafana.unorouter.com) -> firing alerts in Alertmanager -> then
the CLI checks below. 15d retention, so post-mortems no longer need the box caught red-handed.

Rules: `infra/monitoring/extras/rules-unorouter.yaml`, each annotated with the incident it
exists for. Load-bearing wiring:

- **etcd** needs `--etcd-expose-metrics=true` on every k3s server unit (else :2381 is
  localhost-only). Targets are a STATIC IP list in `extras/scrape-etcd.yaml` -- **update on
  every node swap** or etcd alerts go silently blind.
- **Backup freshness** reads the CNPG `Backup` CRs via kube-state-metrics.
  `cnpg_collector_last_available_backup_timestamp` is permanently 0 with the Barman PLUGIN --
  do not "fix" the alert back to it.
- **Alertmanager routing** is an `AlertmanagerConfig` CRD, not the chart's inline `config:`
  (only the CRD's `discordConfigs.apiURL` takes a Secret ref, keeping the webhook out of git).
  Root receiver is `null`; only critical/warning reach Discord. Making `discord` the root
  spams the channel with `Watchdog`/`InfoInhibitor`.
- **A new ops hostname needs TWO restarts, not just a push**: `kubectl -n dex rollout restart
  deploy/dex` (new OIDC client) AND `kubectl -n cloudflared rollout restart deploy/cloudflared`
  (tunnel reads its ingress list only at startup). Both serve stale config while the configmaps
  look correct -- symptom is a 404 with correct-looking YAML everywhere.

**Dead-man switch (live 2026-07-25)**: the always-firing `Watchdog` alert is routed to a webhook
receiver that POSTs healthchecks.io every 5m. If the cluster, Prometheus or Alertmanager dies
the pings stop and healthchecks emails after a 15m grace -- the one failure mode in-cluster
alerting can never report about itself. Ping URL is in OpenBao `secret/alertmanager`
(`healthchecksPing`), delivered by ESO; check period 5m / grace 15m must stay >= the route's
`repeatInterval` or it will false-alarm.

## Access + SSO

1. **Teleport** (primary, audited): `tsh login --proxy=teleport.unorouter.com --auth=github`
   -> `tsh kube login unorouter`. Agent runs `roles: app,db,kube` + `kubeClusterName: unorouter`;
   the `kube-admin` role grants `kubernetes_groups: [system:masters]`, mapped to the GH
   `unorouter/admins` team. Role/connector applied via tctl (connector needs client_secret from
   OpenBao `secret/teleport-github`). **GOTCHA**: `tsh login` reusing a valid cert keeps the OLD
   roles -- after any connector change, `tsh logout` THEN login.
2. **Direct kubeconfig**: `kubectl --context unorouter-direct` or
   `export KUBECONFIG=$PWD/kubeconfig` (hits node1 :6443).
3. **Raw SSH**: `ssh root@$(./scripts/dr.sh NODE_IP unorouter-node1)` (or `dr.sh ips` to list
   all) -- for the layer BELOW k8s (etcd/quorum recovery, k3s install/stop, disk/journal) when
   the kube API itself is dead.

**No local passwords anywhere**: Teleport `local_auth: false`, ArgoCD `admin.enabled: false`
(cloud-init helm values), Grafana login form disabled, OpenBao has only kubernetes/oidc/token.
Grafana never prompts -- Teleport signs each proxied request with a JWT
(`Teleport-Jwt-Assertion`), verified against `/.well-known/jwks.json`; the `roles` claim maps a
Teleport `editor` to Grafana Admin.

**BREAK-GLASS (GitHub/dex down = no ops UI).** Recovery does not depend on SSO: tiers 2 and 3
above, OpenBao root token via `sops -d secrets/openbao-init.sops.yaml`, and for ArgoCD
specifically `kubectl -n argocd patch cm argocd-cm --type merge -p
'{"data":{"admin.enabled":"true"}}'` + restart the server (password still in
`argocd-initial-admin-secret`); revert after.

**Teleport entry IP**: the `teleport.unorouter.com` A record AND the svc `externalIPs`
(`infra/teleport/values.yaml`) both point at **node7** on purpose -- the published/DDoSable IP
must be a sacrificial node, never node1. The two MUST stay in sync: Cilium only answers an
externalIP on the node that owns it, mismatch = connection refused.

## Node swap (CANONICAL -- executed 4x, zero downtime each)

Rules learned the hard way (see incident below). Before ANY node surgery: check where the CNPG
primaries actually run (`kubectl get cluster -n databases`) -- drills move them.

1. **Preflight**: both primaries confirmed, argocd green, WAL archiving True, old node's disk
   fits the new type, ssh to spare ok (`ssh-keygen -R <ip>` first -- Hetzner recycles IPs).
2. **JOIN FIRST**: rename spare (API + `hostnamectl`), install k3s with the exact
   cloud-init-join flags, pinned `INSTALL_K3S_VERSION` -> 4th etcd member, quorum never dips
   below tolerate-1. Verify BEFORE proceeding: 4 Ready, `/readyz/etcd` ok, cilium-health 4/4
   from BOTH the old and new node's agent (probe cycle ~2min, wait it out).
3. **Evacuate**: cordon, then evict singletons ONE at a time as individual `kubectl delete pod`
   (wait Ready + endpoint 200 between each), THEN `drain --ignore-daemonsets
   --delete-emptydir-data`.
4. **pg replicas** go Pending (local-path PVCs are node-pinned): delete PVC + pod, CNPG
   re-clones from the primary. ONE CLUSTER AT A TIME, wait 3/3 then 2/2 (~1-6min each).
5. **Remove**: `systemctl stop && disable k3s` on the old node FIRST, then `kubectl delete
   node`, then `tofu plan -destroy -target=hcloud_server.nodeX -out=f` -- READ it (exactly 1
   destroy) -- `tofu apply f`. Plan-file apply = the reviewed plan is the executed plan.
6. **Import**: add the node.tf block (hardcoded server_type, `lifecycle ignore_changes
   [user_data, ssh_keys]` -- hand-built, template is DR-rebuild-only), `tofu import`, apply the
   in-place reconcile (expect `+ network`; ABORT on any replace/destroy). Final plan = No changes.

**Drive the whole swap from the DIRECT kubeconfig.** The Teleport kube context routes through
the in-cluster apiserver Service, which loses endpoints mid-swap -> `kubectl delete node` fails
with `dial 10.43.0.1:443 connection refused`. Teleport reconverges once etcd is back to 3.

Deltas seen so far, by what the old node carried:

| Carried | Extra step |
| --- | --- |
| singletons (master, bot, cilium-operator) | evict individually before the bulk drain |
| teleport-app-access-0 | evict too; harmless reconnect |
| pg replicas | delete PVC+pod, one cluster at a time |
| **Teleport ENTRY node** | graceful cutover BEFORE draining, below |

**Entry-node cutover** (node5 -> node7 needed this; no earlier swap did): add the new IP
ALONGSIDE the old in `infra/teleport/values.yaml` externalIPs, push, ArgoCD self-heals (~90s) ->
verify BOTH answer (`curl --resolve teleport.unorouter.com:443:<ip> .../webapi/ping` = 200) ->
PATCH the grey-cloud `teleport` A record to the new IP (CF API; zone + record id and the
`cfat_` Bearer token are in the operator's own notes, not this repo) -> confirm DNS + ping 200
BEFORE touching the old node (its IP is still listed = fallback) -> drain -> drop the old IP.

## INCIDENT 2026-07-23: quorum loss + 34min DB-write outage (self-inflicted)

`TF_VAR_ha_node_type=cpx22 tofu apply -replace=hcloud_server.node2` -- the env override changed
BOTH nodes' server_type, so the plan replaced node2 AND node3; node3 was destroyed UNDRAINED.
etcd lost 2 of 3 members: quorum gone, apiserver down, CNPG could not promote -> "Database
error" on all logins/writes for ~34min. Public reads kept serving off node1. Zero data loss.

1. NEVER combine a blast-radius-widening var override with `-replace`/`-auto-approve`. ALWAYS
   `tofu plan` and READ the add/change/destroy lines. One node at a time = exactly one destroy.
2. Quorum-loss recovery: `k3s server --cluster-reset` on the survivor MUST pass the SAME
   `--node-ip`/`--advertise-address` as the service unit, or membership is written with the
   PUBLIC peer URL and k3s wedges on "not a member of the etcd cluster". Run under `nohup`.
   Stop/disable k3s on all OTHER nodes first (their join storm destabilizes the fresh
   single-member etcd: "too many learner members").
3. Rejoin nodes ONE at a time, `rm -rf /var/lib/rancher/k3s/server/db` first.

## INCIDENT 2026-07-23 night: frontend crashloop ~8h (site 502, API fine)

`unorouter-env` was missing `INTERNAL_API_URL` (don injected it via compose, not .env) ->
frontend server-side calls fell back to the PUBLIC api hostname (hairpin: pod -> CF edge ->
tunnel -> back in) -> Cloudflare L3/4 auto-mitigation dropped the node's IPv4 mid-TLS-handshake
for our zone only (v6 fine, other zones fine, external clients fine, invisible in zone security
events) -> `/api/ops/health` hung >5s -> the liveness probe (same endpoint, 5s timeout) killed
both replicas all night.

Fixes: liveness = **tcpSocket only** (killing a pod never fixes a slow external dep), readiness
keeps the dep check at 10s; `INTERNAL_API_URL=http://new-api.services.svc.cluster.local:3000`
so in-cluster server-side traffic never leaves the cluster; node IP whitelisted in CF (belt).

Lesson: when migrating a service, diff `docker inspect <c> .Config.Env` against the k8s secret,
not just the .env file.

## Rebuild from total loss

The node is disposable cattle; durable state lives OFF-node.

**Survives `tofu destroy`**: Hetzner S3 (`unorouter-pg-backups`, `prevent_destroy` -- CNPG base
backups + WAL, OpenBao snapshots, tofu remote state; it is in its OWN tofu state under
`tofu/storage/` so `make destroy` cannot reach it), git, SOPS secrets in git, the age key
(offline!), Bitwarden (2nd copy of unseal keys), Cloudflare DNS.

**Dies**: nodes + disks, k3s + etcd, ALL local-path PVs (CNPG PGDATA, OpenBao raft, Teleport
SQLite, ArgoCD, monitoring), every pod.

**PRE-DESTROY on a live cluster**: scale writers to 0 (new-api master+slaves, bot),
`SELECT pg_switch_wal()` + verify the segment archived, force a fresh OpenBao snapshot
(`kubectl -n openbao create job --from=cronjob/openbao-raft-snapshot ...` -- the 6h cron can
predate recent rotations), commit the lineage bump (step 2, create-time-only), THEN destroy.
Skipping the WAL flush loses the last <=5min of writes.

### 1. Recreate (zero-touch)

```sh
make apply    # tofu apply -> cloud-init auto-deploys Cilium + ArgoCD + root app-of-apps
```

Cloud-init writes k3s auto-deploy manifests, so `tofu apply` ALONE brings up the whole stack
from git (`make bootstrap` is a fallback only).

**DR now spans MORE THAN THIS REPO.** This repo restores the platform (nodes, Cilium, ArgoCD,
CNPG operator, OpenBao, ESO, Teleport, monitoring) plus the `services` ApplicationSet. The
workloads and their databases live in the app repos and are rediscovered from there:
`unorouter/unorouter`, `unorouter/new-api`, `unorouter/unorouter-bot` (each `k8s/`). A restore
is only complete once those three Applications appear -- check
`kubectl -n argocd get app` for them, and see the discovery + SCM-token notes in the root README.

node1 self-initializes etcd (`--cluster-init`);
the others join on the fixed token, retrying until node1's apiserver is up -- a few minutes of
join errors at boot is normal. node1 has `lifecycle.ignore_changes[user_data]` so template
edits never replace the live node.

If IPs changed: update `infra/teleport/values.yaml` externalIPs + the grey-cloud A record
(tunnel-routed hosts follow automatically), and `operator_cidr` if yours moved.
`ssh-keygen -R <ip>` on any reused IP.

### 2. Bump the CNPG serverName lineage (the ONE unavoidable edit)

CNPG HALTS a restored primary that archives WAL to the path it restored FROM. On every DR
event bump BOTH serverNames by one. **These manifests live in the APP repos now, not here**:
`unorouter/new-api` -> `k8s/pg.yaml`, `unorouter/unorouter-bot` -> `k8s/pg.yaml`.
`externalClusters[].serverName` v{N} -> v{N+1}, `plugins[].serverName` v{N+1} -> v{N+2}.
Commit + push BEFORE the apply. Do NOT set `cnpg.io/skipEmptyWalArchiveCheck` (corrupts the
source). Verify: `kubectl -n databases get cluster newapi-pg bot-pg` -> healthy.

Recover-to-latest is default; for PITR set `bootstrap.recovery.recoveryTarget.targetTime`
before the apply, remove after.

### 3. Restore OpenBao (fresh raft)

```sh
make restore    # temp-init -> restore snapshot -> restart pod -> unseal -> ESO resync
```

Then `tsh login` again (Teleport CA is regenerated). Break-glass if the age key is lost: unseal
keys are in Bitwarden -> `bao operator unseal` by hand.

Post-restore, NOT reconciled from git:
- **Dex reads config only at boot** -- `kubectl -n dex rollout restart deploy/dex` after any
  change, or logins fail with "Unregistered redirect_uri" while the configmap looks correct.
- **OpenBao's OIDC role redirect is a runtime `bao write`**, not a manifest. Re-set it on DR or
  any hostname change -- role writes REPLACE the whole role, so send every field:
  ```sh
  bao write auth/oidc/role/admin \
    allowed_redirect_uris='https://openbao.unorouter.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback' \
    user_claim=email token_policies=admin bound_audiences=openbao \
    oidc_scopes=openid,profile,email,groups groups_claim=groups \
    token_ttl=168h token_max_ttl=768h
  ```
  Dex must also allow that callback. `token_ttl=168h` keeps the UI session alive a week.
- **CI's GitHub-OIDC auth path is runtime state too.** The app repos hold ZERO GitHub secrets;
  every build fetches from OpenBao by exchanging a GitHub-signed JWT. A raft snapshot restore
  carries the mount, policy and role; a vault rebuilt WITHOUT a snapshot does not, and then
  every image build fails at "Fetch build secrets from OpenBao" with a 403. Recreate with
  `./scripts/openbao-ci-auth.sh` (idempotent).
  The public endpoint it needs, `openbao-ci.unorouter.com`, IS in git (`infra/cloudflared`) --
  it deliberately bypasses Teleport because GitHub runners cannot pass an interactive SSO
  login. That is safe only because the role's `bound_claims` rejects any JWT whose
  `repository` claim is not `unorouter/unorouter`; do not relax that to make another repo work.
- **Building without GitHub Actions**: `./scripts/build-local.sh <repo> [--deploy]` pulls the
  same secrets from OpenBao, builds, pushes to GHCR and (with `--deploy`) pins the SHA so
  ArgoCD rolls it out. Used when Actions is down; needs `secret/ghcr-push`.
- **OpenBao UI defaults to the Token tab**: `bao auth tune -listing-visibility=unauth oidc/`
  makes OIDC the default (re-apply on DR). Known caveat (vault#10816): it snaps back after
  logout. Bookmark `openbao.unorouter.com/ui/vault/auth?with=oidc%2F`.
- **Teleport is stateless by design** (fresh SQLite): reapply `infra/teleport/resources/*.yaml`
  (github connector needs client_secret from OpenBao `teleport-github`); users `tsh login` again.
- **Teleport db-client CA is regenerated** -> rebuild the `newapi-pg-client-ca` bundle: own CA
  cert (first block, key unchanged in OpenBao) + fresh `tctl auth export --type=db-client`. ESO
  resyncs, `cnpg.io/reload` reloads postgres. ca.key must be SEC1 ("BEGIN EC PRIVATE KEY") --
  CNPG rejects PKCS8.
- k8s auth is SELF-HEALING (kubernetes.default.svc + no token_reviewer_jwt) -- no reconfigure
  after rebuild, just restart ESO if it cached a failure.
- Races that self-heal: CNPG recovery jobs fail until ESO delivers the S3 secrets; velero can
  deadlock its first sync -- clear the operation + refresh.

VERIFIED x2 (2026-07-22 destroy -> apply -> restore): 14 apps reconciled, both CNPG clusters
restored from S3 with WAL replay (users=8531 exact), services 200 via tunnel, SSO working, zero
manual auth steps.

## Notes

- **Hetzner Ceph S3**: boto3>=1.36 checksum headers hang multipart base backups
  (`AWS_*_CHECKSUM_*=when_required` in `Cluster.spec.env` fixes it; WAL unaffected). A healthy
  1GB backup takes ~15min and logs NOTHING at default level (`-vv` shows parts). Test-restore
  from the REAL bucket is a HARD GATE (cnpg#6645).
- The `options_masked` view + `reader` role ride the physical S3 backup -- no post-restore SQL.
- Nodes reach each other on the private net; node SSH is public-IP + firewall :22.
- don was decommissioned 2026-07-23 (revenue containers removed, DB ports closed, volumes kept
  as a cold archive). Rollback is the k3s DR path only. Its "Docker Prod" workflows are DISABLED
  in all three repos -- one zombie-respawned after cutover and ran 11h in parallel on a stale DB,
  burning shared upstream rate limits. GHCR builds stay active; k3s deploy is a manual
  `kubectl rollout restart` (no image updater yet).
- Drills passed 2026-07-23: node drain (30/30 probes 200), pg primary kill (promotion ~70s,
  25/25 probes 200, old primary auto-rejoined).
