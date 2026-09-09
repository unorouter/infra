# Backups

Everything is on Hetzner Object Storage (fsn1). Hetzner has no at-rest encryption, so the in-cluster
s3-gateway (`infra/monitoring/extras/s3-gateway.yaml`, `s3.unorouter.com` via CoreDNS rewrite)
encrypts client side with rclone crypt: content only, names in clear, Hetzner never sees the key, the
ciphertext copies to any provider as is. Key: OpenBao `secret/backup-encryption` (`crypt_password`,
`crypt_salt`), break-glass copy `secrets/backup-encryption.sops.yaml` (opened by the age key on the
VeraCrypt volume and in Bitwarden, nothing else to keep). Lose the pair, lose every encrypted object.

## Rules

- `unorouter-backups` is Object Locked (COMPLIANCE, 30d) and `unorouter-logs` (COMPLIANCE, 90d since
  2026-09-09; objects written before keep their 30d). Nothing deletes, the lifecycle expires. No barman
  `retentionPolicy`. After a bucket change Hetzner frontends may briefly
  write objects without retention or answer `NoSuchBucket`: sweep with `retention=` and stamp.
- `unorouter-loki` is unlocked AND unversioned: Loki's compactor deletes expired chunks and rewrites the
  index, and with `auth_enabled: false` there is nothing to version. Never enable a lock or versioning on
  it. Its 90 days live in `retention_period` (`infra/loki/values-loki.yaml`), the 120d lifecycle only
  catches a dead compactor.
- `unorouter-velero` is unlocked (Kopia must delete and rewrite, velero-io/velero#8686). Versioning is
  its only protection. Velero backs up no Secrets (ESO, cert-manager and CNPG recreate them; the two
  canaries have `secrets/canaries.sops.yaml`) and only PVs annotated `backup.velero.io/backup-volumes`
  (Teleport auth data, Grafana storage).
- Gateway: one auth pair for every in-cluster writer (`secret/s3gw`), network policy is the boundary.
  Uploads stage in a per pod write cache; the object reaches Hetzner seconds to a minute after the
  writer's 200, a restart in that window loses it. rclone 1.75+ only (older holds multipart in memory).
- CNPG serverName pair: `v7` is archive-to and, since it is only read at bootstrap, also the
  restore-from entry. On a DR create bump archive-to to `v8`, the pair must differ at create time.
  Switching the archive store drops every `Backup` CR: take a base backup right after.
- Key rotation: new `crypt_password` and `crypt_salt`, `bao kv patch`, ESO restart, gateway rollout,
  CNPG serverName bump and base backup, new sops file. Old objects stay readable with the old pair
  until the lifecycle expires them (31 days), then drop it. The pre 2026-09-09 SSE-C key is gone;
  objects from that era (`*-pg-v5`, `*-pg-v6`, `unorouter-evidence`) are unreadable noise until the
  lifecycle removes them on 2026-10-09, the plaintext copies are under `~/backups/`.
- The archive in `unorouter-logs` is written by Vector (`infra/loki/values-vector.yaml`): unique keys
  under `vector/<source>/node=<node>/date=<day>/`, gzip ndjson, never overwritten. The `streams/` and
  `incidents/` prefixes stopped on 2026-09-09 and expire with the lifecycle.
- Restore drill: `databases/dr-drill.yaml` restores bot-pg into a scratch cluster on the 1st of
  each month and counts populated tables; `DRDrillStale` warns after 35 days without a success.
  Run it by hand with `kubectl -n databases create job --from=cronjob/dr-drill dr-drill-manual`.
- `kubectl -n velero get backup` hits CNPG's CRD, use `get backup.velero.io`.
- After patching an S3 credential, restart every consumer that reads it as env, after the
  ExternalSecret synced.
- `tsh play <session>` needs `ListObjectVersions`, which the gateway does not serve. Recordings are
  logs: download the tar through the drill, `tsh play --format=json <file>`.
- Plaintext copies of everything as of 2026-09-09 are on the operator machine under `~/backups/`
  (LUKS, not synced).

## Download and decrypt drill (quarterly)

From a laptop with `tofu/.env` and the break-glass age key:

```bash
export RCLONE_CONFIG_HZ_TYPE=s3 RCLONE_CONFIG_HZ_PROVIDER=Ceph RCLONE_CONFIG_HZ_REGION=fsn1 \
  RCLONE_CONFIG_HZ_ENDPOINT=https://fsn1.your-objectstorage.com RCLONE_CONFIG_HZ_NO_CHECK_BUCKET=true \
  RCLONE_CONFIG_HZ_ACCESS_KEY_ID=... RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY=... \
  RCLONE_CONFIG_CR_TYPE=crypt RCLONE_CONFIG_CR_REMOTE=hz: RCLONE_CONFIG_CR_FILENAME_ENCRYPTION=off \
  RCLONE_CONFIG_CR_DIRECTORY_NAME_ENCRYPTION=false RCLONE_CONFIG_CR_SUFFIX=none \
  RCLONE_CONFIG_CR_PASSWORD=$(rclone obscure "$(sops -d --extract '["stringData"]["crypt_password"]' secrets/backup-encryption.sops.yaml)") \
  RCLONE_CONFIG_CR_PASSWORD2=$(rclone obscure "$(sops -d --extract '["stringData"]["crypt_salt"]' secrets/backup-encryption.sops.yaml)")
rclone copy cr:unorouter-backups/newapi-pg-v7/base/<latest>/ ./nb/ && tar -tzf ./nb/data.tar.gz | head   # PG_VERSION, base/
rclone cat hz:unorouter-backups/newapi-pg-v7/base/<latest>/backup.info | head -c 32 | xxd              # ciphertext
rclone copy cr:unorouter-logs/vector/k8s-audit/node=<node>/date=<day>/<obj>.ndjson.gz ./ && zcat ./<obj>.ndjson.gz | head -1 | python3 -m json.tool
rclone copy cr:unorouter-logs/teleport-recordings/<sid>.tar ./ && tsh play --format=json ./<sid>.tar | head -c 300
rclone copy hz:unorouter-velero/velero/backups/<latest>/ ./vb/ && tar -tzf ./vb/<latest>.tar.gz | grep -c secrets/   # 0
rclone copyto hz:unorouter-backups/openbao-snapshots/latest.snap ./latest.snap && gzip -t ./latest.snap
```

Every `cr:` GET repeated through `hz:` must be ciphertext. Cluster side proof: restore the postgres base
backup into a scratch cluster through the gateway (`bootstrap.recovery` from `externalClusters` with the
`-hz` ObjectStore, no `plugins` block so it never archives). The gateway admits only the production
cluster labels, so the scratch cluster needs a temporary ingress rule in `s3-gateway` for its
`cnpg.io/cluster` label (2026-09-09: the first attempt timed out on exactly that). It needs a node
with twice the database in free disk, `local-path` does not enforce it.
