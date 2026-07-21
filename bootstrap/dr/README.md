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

### 1. Recreate the node + bootstrap

```
make apply       # tofu apply -> fresh node (same or new IP), k3s via cloud-init
make bootstrap   # Cilium + Gateway CRDs + ArgoCD + root app-of-apps
```

IMPORTANT (verified in the 2026-07-22 destroy test): cloud-init installs ONLY k3s + tailscale.
Cilium and ArgoCD are NOT in cloud-init -> `make bootstrap` installs them. Once ArgoCD is up it
reconciles the whole app-of-apps from git: cert-manager, CNPG operator, Vault, ESO, databases.
CNPG `Cluster`s come up (initdb now; `bootstrap.recovery` from S3 once cut over from don).
Vault boots SEALED + UNINITIALIZED (fresh raft).

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

### 3. Restore Vault (fresh raft) -- VERIFIED SEQUENCE from the 2026-07-22 destroy test

A fresh Vault has empty raft. To restore the S3 snapshot you must init it first (temp keys),
restore, then it reverts to the ORIGINAL keys. Exact working sequence:

```
# a. init fresh vault with throwaway 1-of-1 keys (just to enable restore)
kubectl -n vault exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/vtmp.json
kubectl -n vault exec vault-0 -- vault operator unseal $(jq -r .unseal_keys_b64[0] /tmp/vtmp.json)

# b. pull latest.snap from S3 + restore -force (overwrites with ORIGINAL data + keys)
make vault-snapshot-restore   # copies latest.snap into the pod
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=$(jq -r .root_token /tmp/vtmp.json) vault operator raft snapshot restore -force /tmp/latest.snap"

# c. RESTART the pod (MANDATORY -- restored raft state only loads clean after restart,
#    else unseal fails 'invalid key size')
kubectl -n vault delete pod vault-0    # wait for Running

# d. unseal with the ORIGINAL keys (SOPS / Bitwarden), 3 of 5
make vault-unseal

# e. RECONFIGURE k8s auth (MANDATORY -- the restored token-reviewer binding is from the OLD
#    cluster; ESO can't auth until this is redone against the new cluster)
make vault-reconfigure-auth
# then force ESO resync: kubectl -n databases annotate es --all force-sync=$(date +%s) --overwrite
```

Then: `tsh login --proxy=teleport.unorouter.com` (Teleport CA regenerated -> re-login).

Break-glass (age key lost): unseal keys are in Bitwarden -> `vault operator unseal` by hand.

### DR test learnings (2026-07-22, all folded into the steps above)

1. Bucket needs `prevent_destroy` (tofu tried to delete the DR data; `BucketNotEmpty` + the
   lifecycle guard now both protect it).
2. Vault pod MUST be restarted after `snapshot restore -force` or unseal fails.
3. Vault k8s auth MUST be reconfigured after rebuild (cluster-specific token reviewer) or ESO
   fails `SecretSyncedError`.
4. Cilium + ArgoCD are a `make bootstrap` step (not in cloud-init).
VERIFIED: a full destroy/apply cycle recovered all 7 apps + a Vault DR-marker survived.

## Notes

- The `options_masked` view + `reader` role + grants are schema objects -> they ride the
  physical S3 backup and come back on their own. No post-restore SQL. (First-ever migration
  from don applies `databases/newapi-pg/masking.sql` once; see P2.)
- Recover-to-latest is the default (no `recoveryTarget`). For PITR, set
  `bootstrap.recovery.recoveryTarget.targetTime` before the apply, then remove it after.
- TEST the full destroy/apply/restore cycle on a THROWAWAY cluster before trusting it on
  revenue (CNPG#6645 Hetzner-restore is a known sharp edge -- hard gate).
