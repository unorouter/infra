# Backups

All on Hetzner Object Storage (fsn1), every object SSE-C encrypted with ONE key: OpenBao
`secret/backup-encryption` (live), `secrets/backup-encryption.sops.yaml` (break-glass age, for
`dr.sh` before OpenBao exists), VeraCrypt and Bitwarden. Losing the key loses every backup.
Hetzner has no at-rest encryption of its own; a GET without the key is a 400.

| What | Mechanism | Bucket, prefix | Encryption path | Retention |
| --- | --- | --- | --- | --- |
| Postgres PITR | CNPG + Barman plugin, daily base + WAL | `unorouter-backups`, `{newapi,bot}-pg-v6/` | s3-gateway adds SSE-C (barman cannot) | bucket lifecycle 31d, no `retentionPolicy` |
| OpenBao raft | CronJob snapshot, every 6h | `unorouter-backups`, `openbao-snapshots/` | rclone native SSE-C | bucket lifecycle 31d |
| Teleport recordings | `audit_sessions_uri` | `unorouter-backups`, `teleport-recordings/` | s3-gateway adds SSE-C | bucket lifecycle 31d |
| PVs + k8s objects | Velero + Kopia, daily 02:00 | `unorouter-velero`, `velero/` | tarballs SSE-C by the aws plugin, PV data by Kopia (repo password `secret/velero`) | Velero `ttl: 336h`, versioning + 14d noncurrent expiry |
| Security evidence | collector + PAT archive | `unorouter-evidence`, `streams/`, `incidents/` | hand signed SSE-C in the writers | bucket lifecycle 30d |
| Tofu state | `tofu state` | `unorouter-pg-backups` | client side (`tofu/encryption.tf`) | as is |

- `unorouter-backups` and `unorouter-evidence` are Object Locked, COMPLIANCE 30d default
  retention: no writer deletes, not even the key holder can, the lifecycle expires. A plain
  DELETE only adds a delete marker. Hetzner frontends sometimes serve a stale bucket config for
  a while after a change and write objects WITHOUT retention or answer `NoSuchBucket`; sweep with
  `retention=` and stamp what is missing (2026-09-09: about 15% of the safety copy).
- `unorouter-velero` is not locked: Kopia must delete session markers and rewrite indexes
  (velero-io/velero#8686). Versioning is its protection; a key holder can still delete a version.
- The s3-gateway (`infra/monitoring/extras/s3-gateway.yaml`, namespace `s3-gateway`,
  `s3.unorouter.com` via CoreDNS rewrite) stages uploads in a per pod write cache and sends
  them to their final key after the writer finishes: barman and Teleport get their 200 when the
  object is in the cache, the object is on Hetzner a few seconds to a minute later. A restart in
  that window is the residual risk; the cache lives on a PVC. One auth pair per writer,
  `secret/s3gw-<writer>`; any pair reaches every bucket the project key can.
- The CNPG serverName pair: restore-from is `*-pg-v5` (the 2026-09-09 copy of the R2 lineage on
  Hetzner, locked until 2026-10-09), archive-to is `*-pg-v6`. Bump both on every DR create.
- Switching a cluster's archive store makes the plugin delete every `Backup` CR not in the new
  catalog: take a base backup right after and confirm in the `plugin-barman-cloud` log that the
  options name the new endpoint.
- `kubectl -n velero get backup` resolves to CNPG's CRD. Use `get backup.velero.io`.
- After patching an S3 credential, `rollout restart` every consumer that reads it as env AFTER
  the ExternalSecret synced (teleport-auth failed uploads for two hours that way).
- `tsh play <session>` does not work and never did on R2: Teleport reads the oldest object
  version (anti-tamper) and neither R2 nor the gateway serve `ListObjectVersions`. Recordings
  are evidence: download the tar with the key, `tsh play --format=json <file>`.
- Local plaintext copies of everything as of 2026-09-09 live on the operator machine under
  `~/backups/` (LUKS), outside any sync directory.

## Download and decrypt drill (quarterly)

From a laptop with only `tofu/.env` and the break-glass age key:

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

Every GET repeated without the SSE-C variables must return 400. A restore of the postgres base
backup into a scratch cluster through the gateway is the cluster side proof
(`bootstrap.recovery` from `externalClusters` with the `-hz` ObjectStore); it takes a node with
free disk equal to the database twice over, `local-path` does not enforce the request.
