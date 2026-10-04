# Monitoring and alerting

kube-prometheus-stack, Loki and blackbox run on node12 (`nodeSelector` on the label
`unorouter.com/monitoring`, local-path PVCs; a PVC pinned to a dead node stays Pending, delete
PVC and PV). `infra/monitoring/extras/` is applied recursively: `alerting/` (Alertmanager
routing, rules, ntfy-bridge, responders), `pollers/` (CronJobs reading external APIs and SQL),
`scrape/` (targets, blackbox, the CNPG metric queries), `grafana/` (dashboards, datasource).

- **Rules**: `alerting/rules-unorouter.yaml` (platform, each from a real incident) and
  `alerting/rules-security.yaml` (account takeover, card testing, chargebacks, guest abuse), fed by
  SQL over the gateway's Postgres tables in `scrape/cnpg-security-queries.yaml` and over its
  ClickHouse logs and audit trail in `infra/databases/clickhouse-security-exporter.yaml`.
- **Audit canary**: `pollers/audit-canary.yaml` sends one refused request an hour (fake bearer
  token, user agent `uno-audit-canary/1`) and `cnpg_newapi_audit_canary_count` counts its
  audit rows over 3 h. `SecurityAuditCanarySilent` pages at zero: a security metric that reads
  zero forever looks like a quiet night. Whatever exporter serves the security metrics must
  serve this one too, and the credential alerts exclude that user agent (from the pod network
  only, so the public user agent cannot be used to hide).
- **Watching the watchers**: every feed and poller has a staleness alert, sized from its real
  quietest stretch: `K8sAuditLogSilent` (15 m), `TeleportAuditSilent` (3 h), `HubbleExportSilent`
  (6 h), `TalosAPILogSilent`, `TetragonExportSilent`, `NetcupLogsSilent`, and `WatcherStale` /
  `WatcherMissing` for the monitoring CronJobs (`KubeJobFailed` is off as noise). A new watcher
  goes into both regexes in `rules-security.yaml`.
- **Log alerts** are LogQL rules in `infra/loki/logql-rules.yaml` (ConfigMaps labelled
  `loki_rule: "1"`, Loki's ruler, same Alertmanager). Groups: `pgaudit`, `openbao` (root policy
  in use pages), `teleport` (role, connector or user change pages; `TeleportLogin` posts every
  login to Discord), `dex`, `k8s-audit`
  (`K8sPodExec`, `K8sSecretRead`, `K8sSecurityConfigurationChanged` critical,
  `K8sUnexpectedAccess` warning; the owner's own identity `0-don` gets an info digest, never a
  page; `K8sImpersonatedMasters` pages if Teleport ever impersonates `system:masters`). Rules group by actor and strip source ports, one session is one alert. `K8sSecretRead`
  also pages when a service account reads a Secret outside its namespace; platform controllers
  are one regex in the rule. `hubble` pages on any pod reaching the metadata service,
  `talos` on privileged Talos API calls (`talos-apid-log` follows apid), `tetragon` on a
  container reading host secrets and on apid or trustd accepting a caller from outside
  loopback, mesh, pod network and tailnet (`infra/tetragon`; every caller address is kept), `netcup` on shell logins, sensitive file
  access, a silent journal and a cluster secret on disk (hourly `/usr/local/bin/cluster-secret-scan`
  timer on netcup, `NetcupSecretScanSilent` when it stops reporting), `apps` on bot messages without a matching request and gateway
  lane disable storms.
- **Pollers** (`cloudflare-audit-watch`, `edge-probe-watch`, `ghcr-visibility-watch`,
  `github-watch`, `hetzner-watch`, `image-secret-scan`, `pat-audit-archive`, `tailscale-watch`)
  speak only to
  Alertmanager through `pollers/watch-lib.yaml` (`notify.digest` info, `notify.alert`
  critical). No poller holds the Discord webhook. Each uses a read only credential of its own:
  a Tailscale OAuth client, a read only Hetzner token, the `unorouter-github-watch` GitHub App.
  `netcup-journal` is not a poller but a Deployment following netcup's journal into Loki.
  Teleport sees only pod addresses behind the tunnel (`trust_x_forwarded_for` breaks IPv6
  `tsh`), so `edge-probe-watch` posts each Teleport sign-in (`TeleportSignin`) with the real
  client address from Cloudflare's request log.
- **Which alerts reach the phone** is one allowlist regex in
  `alerting/alertmanager-config.yaml`; a new critical alert that should page goes there too.
  A new critical alert also starts with the label `burn_in: "until-<date a week out>"`: both
  phone routes skip any alert carrying it, so it posts to Discord only until the label is
  removed after a quiet week.
- **Responders** are Alertmanager webhook receivers, one Deployment each: `edge-mode` flips the
  Cloudflare zone into attack mode on `CloudflaredStreamFlood` and back 30 min after resolve.
  Detect in a rule, route in Alertmanager, act in a responder; never a log tailer.
- **Routing is drop-by-default**: root receiver `null`; critical and warning reach Discord
  through `alerting/ntfy-bridge.yaml` (severity-coloured embeds, one log line per delivery),
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **Logs**: Vector (DaemonSet, `infra/loki/values-vector.yaml`) tails `/var/log/pods`, the
  apiserver audit files and the Hubble export; Tetragon's process records arrive as the pod log
  of its `export-stdout` container, with key shaped arguments already redacted by Tetragon.
  Raw lines go to Loki (`infra/loki/values-loki.yaml`),
  chunks and index through the s3-gateway in `unorouter-loki`, 90 d, which is also the PII
  retention (gateway logs carry IPs and emails; Grafana behind Teleport is the only reader). A
  sanitized subset goes write-once into the locked `unorouter-logs`, encrypted by the
  s3-gateway on the way (read it directly with the rclone crypt remote in `docs/dr.md`): per
  pod family a field allowlist in the `pods_archive` transform (openbao, gateway and bot
  `security.` events, postgres audit, teleport, netcup, talos, tetragon), the audit log, the
  Hubble flows, and every other pod line as family `app` with bearer tokens, key, token and
  password values and key shaped strings replaced by `*****` (raw postgres server lines stay
  out). The archive is the complete record for 90 days: Loki or any other search layer can be
  refilled from it. Labels are only
  `namespace, pod, container, node, app, stream` (audit: `job="k8s-audit", node`), everything
  else is a query-time parser: `{namespace="services"}`, `{job="k8s-audit"} | json |
  verb="create"`. Vector health is `infra/loki/rules.yaml`.
- etcd targets come from node discovery (`scrape/etcd.yaml`, port 2381 on the mesh address).
  Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients, blackbox config and the ConfigMap code of ntfy-bridge and edge-mode are read
  at boot: `rollout restart` after a change, ArgoCD only updates the
  ConfigMap.

## Cloudflare edge

`infra/cloudflare/unorouter.com/`: `rules.sops.yaml` (normal), `rules.attack.sops.yaml` (attack),
one key per ruleset phase, encrypted because the rule text is the attacker's playbook.
`apply.sh [normal|attack] [phase...]` PUTs each phase with a zone-scoped `CF_API_TOKEN` and
fetches the daily sops key from OpenBao itself. Intent: machine surface (relay paths, PAT calls,
preflights, webhooks, MCP) skips bot management; browser surfaces are challenged on signal; a
per-IP auto-ban catches single-source floods. Details: `incidents/2026-09-03-l7-ddos.md`.

- A challenge only renders on a page navigation. A fetch, service worker, manifest or OAuth start
  cannot, so those paths are skipped or blocked, never challenged (9,345 silent failures in one
  day before this rule).
- Pro until 2027-09. Downgrade day: `CF_PLAN=free ./apply.sh`.
- **After every rule change**: allowlist checks from the incident report, then `./mitigations.py
  <hours>`. A webhook sender, CLI client or OPTIONS preflight in that list is a false positive.
- Header-name checks must use `lower(http.request.headers.names[*])`.
- 504s with origin status 0 and UA "…early hints" are Cloudflare synthetics, filter them out
  before reading any 5xx rate.
