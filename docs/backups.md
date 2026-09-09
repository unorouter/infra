# Backups

Everything is on Hetzner Object Storage (fsn1), SSE-C encrypted with one key: OpenBao
`secret/backup-encryption` (live), `secrets/backup-encryption.sops.yaml` (break-glass, for `dr.sh`
before OpenBao exists), VeraCrypt, Bitwarden. Lose the key, lose every backup. A GET without it is 400.

| What | Mechanism | Bucket, prefix | Encrypted by | Retention |
| --- | --- | --- | --- | --- |
| Postgres PITR | CNPG + Barman plugin, daily base + WAL | `unorouter-backups`, `{newapi,bot}-pg-v6/` | s3-gateway | lifecycle 31d |
| OpenBao raft | CronJob, every 6h | `unorouter-backups`, `openbao-snapshots/` | rclone SSE-C | lifecycle 31d |
| Teleport recordings | `audit_sessions_uri` | `unorouter-backups`, `teleport-recordings/` | s3-gateway | lifecycle 31d |
| PVs + k8s objects | Velero + Kopia, daily 02:00 | `unorouter-velero`, `velero/` | aws plugin (tarballs), Kopia (PV data, password `secret/velero`) | `ttl: 336h`, 14d noncurrent |
| Security evidence | collector + PAT archive | `unorouter-evidence`, `streams/`, `incidents/` | signed SSE-C in the writers | lifecycle 30d |
| Tofu state | `tofu state` | `unorouter-pg-backups` | client side (`tofu/encryption.tf`) | as is |

## Rules

- `unorouter-backups` and `unorouter-evidence` are Object Locked (COMPLIANCE, 30d). Nothing deletes,
  the lifecycle expires. No barman `retentionPolicy`. After a bucket change Hetzner frontends may
  briefly write objects without retention or answer `NoSuchBucket`: sweep with `retention=` and stamp.
- `unorouter-velero` is unlocked (Kopia must delete and rewrite, velero-io/velero#8686). Versioning
  is its only protection.
- s3-gateway (`infra/monitoring/extras/s3-gateway.yaml`, `s3.unorouter.com` via CoreDNS rewrite)
  stages uploads in a per pod write cache; the object reaches Hetzner seconds to a minute after the
  writer's 200. A gateway restart in that window loses the upload. One auth pair per writer,
  `secret/s3gw-<writer>`; any pair reaches every bucket. Needs rclone 1.75+, older versions hold
  multipart uploads in memory.
- CNPG serverName pair: restore-from `*-pg-v5` (the 2026-09-09 copy, locked until 2026-10-09),
  archive-to `*-pg-v6`. Bump both on every DR create. Switching the archive store drops every
  `Backup` CR: take a base backup right after.
- `kubectl -n velero get backup` hits CNPG's CRD, use `get backup.velero.io`.
- After patching an S3 credential, restart every consumer that reads it as env, after the
  ExternalSecret synced.
- `tsh play <session>` needs `ListObjectVersions`, which the gateway does not serve. Recordings are
  evidence: download the tar with the key, `tsh play --format=json <file>`.
- Plaintext copies of everything as of 2026-09-09 are on the operator machine under `~/backups/`
  (LUKS, not synced).

## Download and decrypt drill (quarterly)

From a laptop with `tofu/.env` and the break-glass age key:

```bash
export RCLONE_CONFIG_HZ_TYPE=s3 RCLONE_CONFIG_HZ_PROVIDER=Ceph RCLONE_CONFIG_HZ_REGION=fsn1 \
  RCLONE_CONFIG_HZ_ENDPOINT=https://fsn1.your-objectstorage.com RCLONE_CONFIG_HZ_NO_CHECK_BUCKET=true \
  RCLONE_CONFIG_HZ_ACCESS_KEY_ID=... RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY=... \
  RCLONE_CONFIG_HZ_SSE_CUSTOMER_ALGORITHM=AES256 \
  RCLONE_CONFIG_HZ_SSE_CUSTOMER_KEY_BASE64=$(sops -d --extract '["stringData"]["sse_c_key_b64"]' secrets/backup-encryption.sops.yaml) \
  RCLONE_CONFIG_HZ_SSE_CUSTOMER_KEY_MD5=$(sops -d --extract '["stringData"]["sse_c_key_md5_b64"]' secrets/backup-encryption.sops.yaml)
rclone copy hz:unorouter-backups/newapi-pg-v6/base/<latest>/ ./nb/ && tar -tzf ./nb/data.tar.gz | head   # PG_VERSION, base/
rclone copyto hz:unorouter-backups/openbao-snapshots/latest.snap ./latest.snap && gzip -t ./latest.snap
rclone copy hz:unorouter-backups/teleport-recordings/<sid>.tar ./ && tsh play --format=json ./<sid>.tar | head -c 300
rclone copy hz:unorouter-evidence/streams/<source>/<id>.json ./ && python3 -m json.tool ./<id>.json | head
```

Every GET repeated without the SSE-C variables must return 400. Cluster side proof: restore the
postgres base backup into a scratch cluster (`bootstrap.recovery` from `externalClusters` with the
`-hz` ObjectStore); it needs a node with twice the database in free disk, `local-path` does not enforce it.
