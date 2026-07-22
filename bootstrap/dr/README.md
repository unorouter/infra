# Disaster Recovery runbook

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
