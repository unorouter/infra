# Backups

All to Cloudflare R2 `unorouter-backups` (Hetzner S3 holds only the tofu state).

| What | Mechanism | Retention | Prefix |
| --- | --- | --- | --- |
| Postgres PITR | CNPG + Barman plugin, daily base + WAL | 30d per ObjectStore | `{newapi,bot}-pg-v5/` |
| PVs + k8s objects | Velero + Kopia, daily 02:00 | `ttl: 336h` | `velero/` |
| OpenBao raft | CronJob snapshot | bucket lifecycle | `openbao-snapshots/` |
| Teleport recordings | `audit_sessions_uri` | bucket lifecycle | `teleport-recordings/` |

- `retentionPolicy` unset = nothing ever expires (reached 81 GiB once).
- Switching a cluster's archive store makes the plugin delete every `Backup` CR not in the new
  catalog: take a base backup right after, but wait a minute and confirm in the
  `plugin-barman-cloud` log that the options name the new endpoint.
- `kubectl -n velero get backup` resolves to CNPG's CRD. Use `get backup.velero.io`.
- After patching an S3 credential, `rollout restart` every consumer that reads it as env AFTER
  the ExternalSecret synced (teleport-auth failed R2 uploads for two hours that way).
