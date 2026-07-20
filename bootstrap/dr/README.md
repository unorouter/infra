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

### 1. Recreate the node

```
cd tofu
set -a; . ./.env; set +a
tofu apply
```

cloud-init installs k3s (Cilium flags) + bootstraps Cilium + ArgoCD. ArgoCD then syncs the
app-of-apps: CNPG operator comes up, the `newapi-pg` / `bot-pg` `Cluster`s RESTORE from S3
automatically (`bootstrap.recovery`, create-time-only). Vault boots SEALED. Teleport boots
with a fresh SQLite backend (new CA).

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

### 3. Unseal Vault + re-login Teleport

```
make restore   # from repo root: unseals Vault (SOPS+age), restores raft snapshot if fresh
tsh login --proxy=teleport.unorouter.com   # Teleport CA regenerated -> everyone re-logs in
```

Break-glass (age key lost): the Vault unseal key is in Bitwarden -> `vault operator unseal`
by hand (3 shares if Shamir-split).

## Notes

- The `options_masked` view + `reader` role + grants are schema objects -> they ride the
  physical S3 backup and come back on their own. No post-restore SQL. (First-ever migration
  from don applies `databases/newapi-pg/masking.sql` once; see P2.)
- Recover-to-latest is the default (no `recoveryTarget`). For PITR, set
  `bootstrap.recovery.recoveryTarget.targetTime` before the apply, then remove it after.
- TEST the full destroy/apply/restore cycle on a THROWAWAY cluster before trusting it on
  revenue (CNPG#6645 Hetzner-restore is a known sharp edge -- hard gate).
