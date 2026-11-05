# Monitoring and alerting

Grafana and Loki run on node12 (`nodeSelector` on the label `unorouter.com/monitoring`,
local-path PVCs; a PVC pinned to a dead node stays Pending, delete PVC and PV). So that one node
outage neither blinds the scrape nor stops pages (node12 was cut off for 8 minutes on
2026-11-04): Prometheus runs two independent replicas (node12, node13, each with its own PVC;
Alertmanager dedupes), Alertmanager three gossiping replicas (one per node, port 9094),
ntfy-bridge and blackbox two each on different nodes, and kube-state-metrics one replica kept
off the Prometheus nodes that leaves a lost node after 30 s. `infra/monitoring/extras/` is applied recursively: `alerting/` (Alertmanager
routing, rules, ntfy-bridge, responders), `pollers/` (CronJobs reading external APIs and SQL),
`scrape/` (targets, blackbox, the CNPG metric queries), `grafana/` (dashboards, datasource).

- **Rules**: `alerting/rules-unorouter.yaml` (platform, each from a real incident) and
  `alerting/rules-security.yaml` (account takeover, card testing, chargebacks, guest abuse), fed by
  SQL over the gateway's Postgres tables in `scrape/cnpg-security-queries.yaml` and over its
  ClickHouse logs and audit trail in `infra/databases/clickhouse/security-exporter.yaml`.
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
- **Which alerts reach the phone** is a label on the rule: `page: "true"` (with severity
  critical, or any severity on the `k8s-audit-watch` evidence route). Pollers get it on every
  critical through `pollers/watch-lib.yaml`. A renamed alert keeps paging; a new one pages
  only if its rule carries the label.
  A new critical alert also starts with the label `burn_in: "until-<date a week out>"`: both
  phone routes skip any alert carrying it, so it posts to Discord only until the label is
  removed after a quiet week.
- **Responders** are Alertmanager webhook receivers, one Deployment each: `edge-mode` flips the
  Cloudflare zone into attack mode on `CloudflaredStreamFlood` and back 30 min after resolve.
  Detect in a rule, route in Alertmanager, act in a responder; never a log tailer.
- **Dead man's switches**: Watchdog fires only while its Prometheus scrapes at least two of the
  three node exporters (`alerting/rules-quorum.yaml`, recording rule `unorouter:scrape_quorum`).
  Alertmanager sends it two ways. Every 5 minutes through ntfy-bridge to healthchecks.io, which
  emails after its grace period (withheld while ntfy fails or a silence is active). Every minute
  straight to netcup over the tailnet (`http://<netcup tailnet ip>:19532/watchdog`, Tailscale
  grant node11..13 to tag:ops on 19531 and 19532): `am-heartbeat serve` (systemd
  `am-heartbeat.service`, user `am-heartbeat`) records it, and `am-heartbeat-check.timer` pages
  ntfy (urgent) and Discord after 5 minutes without one, again hourly, and posts once when it is
  back. Script `/usr/local/bin/am-heartbeat`, ntfy topic and Discord webhook in
  `/etc/am-heartbeat.env` (root, 600, copied from the `ntfy-bridge` Secret: update it when either
  rotates), state in `/var/lib/am-heartbeat`. Nothing in the cluster is on that paging path, so
  it covers the cluster's own uplink, every Alertmanager and both Prometheus being down.
- **Scrape quorum guard**: alerts that only mean "this Prometheus cannot reach it" (`up == 0`,
  `absent()` of a kube-state-metrics series, blackbox probes, etcd member count, Keeper leader)
  end with `and on() unorouter:scrape_quorum`, so a replica that lost its node's uplink stays
  quiet while the other one, which still sees the majority, reports what is really down. Add it
  to any new alert of that kind.
- **Routing is drop-by-default**: root receiver `null`; critical and warning reach Discord
  through `alerting/ntfy-bridge.yaml` (severity-coloured embeds, one log line per delivery),
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **Logs**: Vector (`infra/loki/values-vector.yaml`) ships pod logs, the apiserver audit files,
  the Hubble export and Tetragon's records (the pod log of its `export-stdout` container, key
  shaped arguments redacted). Raw lines go to Loki (`values-loki.yaml`), stored through the
  s3-gateway in `unorouter-loki` for 90 d, which is also the PII retention (gateway logs carry
  IPs and emails; Grafana behind Teleport is the only reader). A sanitized copy goes write-once
  into the locked `unorouter-logs` (read it with the rclone crypt remote in `docs/dr.md`): a
  field allowlist per pod family (`pods_archive` transform), the audit log, the Hubble flows,
  and every other line as family `app` with tokens, keys and passwords replaced by `*****`
  (raw postgres server lines stay out). It is the complete 90 day record and can refill Loki.
  Labels are only `namespace, pod, container, node, app, stream` (audit: `job="k8s-audit",
  node`); everything else is parsed at query time (`{job="k8s-audit"} | json |
  verb="create"`). Vector health: `infra/loki/rules.yaml`.
- etcd targets come from node discovery (`scrape/etcd.yaml`, port 2381 on the mesh address).
  Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients, blackbox config and the ConfigMap code of ntfy-bridge and edge-mode are read
  at boot: `rollout restart` after a change, ArgoCD only updates the
  ConfigMap.

## Fingerprint autoban (fp-autoban)

`infra/monitoring/extras/alerting/fp-autoban.yaml`, a Deployment in `monitoring`, DRY RUN
(`FP_LIVE=0`): candidates post to Discord with the Cloudflare expression it would add. Inputs,
read from Loki every minute: the gateway's ` | fp ` field on its `[GIN]` line, the site's `[fp]`
line (anonymous documents that reached Next) and the site's `[fp-shed]` line (renders the
admission gate in `unorouter/patches/next-bun-compile@*.patch` answered 503 before Next ran,
sampled: first 3 per second, then every 20th, at most 10 lines per second per pod). Each shed
line carries `w`, the shed requests it stands for; the controller counts it `w` times, so request
totals are real and only distinct address counts are a sample. Before `[fp-shed]` existed a flood
left almost nothing: the 2026-11-05 17:35 wave (about 330k requests in a minute) wrote 47 lines.

Tiers, on the 10 minute window, never for a fingerprint a logged in request carried (window or
7 day baseline): `strong` (Chrome 110+ with one ciphers and extensions pair on 2 or more
addresses AND a hello Chrome never sends, at `FP_STRONG_MIN_REQUESTS` 30), `fixed` (that pair on
`FP_FIXED_IPS` 5 addresses, `FP_FIXED_MIN_REQUESTS` 40), `short` (Chrome 131+ or Firefox 132+
hello under 1000 bytes, `FP_SHORT_MIN_REQUESTS` 60 from `FP_SHORT_MIN_IPS` 3), `base` (any signal
at `FP_MIN_REQUESTS` 120 from `FP_MIN_IPS` 5). The ciphers hash alone does not vary per
connection (34 values in an hour of logged in Chrome), the extensions hash does (2,754 values in
2,757 pairs), so the PAIR is what a fixed stack repeats. Firefox and Safari repeat pairs on their
own and get no `fixed` tier. Replayed against the logged in baseline: the 2026-11-04 21:03 wave
(Chrome/121 and /125 user agents, hello 274 and 513) is a candidate at 21:05, the 2026-11-05
wave at 17:36 (first full minute, the controller would post at about 17:37:30), and three hours of
normal traffic (2026-11-05 12:00 to 15:00) plus two crawler bursts give none. Lower thresholds only
add logged in API clients, which the exclusion drops.

### Archive

Through the s3-gateway into the unlocked, versioned `unorouter-sync` bucket (crypt ciphertext,
names in clear), writer pair `secret/s3gw` in the `fp-autoban` ExternalSecret:

- `fp-autoban/runs/YYYY/MM/DD/HHMM.jsonl.gz`: one object per 10 runs (and on SIGTERM), never
  overwritten, one JSON line per run: `t`, `code` (sha256 of `autoban.py`), `thresholds`,
  `baseline`, `window` totals, `top_asn` with shares, `candidates` (tier, signals, counts,
  exclusion, evidence, would be expression), `wave`, and `minutes`: every group of each new
  minute with counts, shed weight, ASNs, top user agents, paths and whether it was in the
  baseline, so a replay rebuilds any window. About 25 MB a day. Lifecycle `fp-autoban-runs-180d`.
- `fp-autoban/waves/<YYYYMMDDTHHMMZ>/`: when a minute has a candidate, a fingerprint with 300
  anonymous requests (`FP_WAVE_ANON_PER_MINUTE`) or 200 shed renders (`FP_WAVE_SHED_PER_MINUTE`),
  `lines.jsonl.gz` holds the raw lines of the whole window, `lines-HHMM.jsonl.gz` each further
  window while it lasts (closed after a quiet window), `run.json.gz` the run that opened it.
  Lifecycle `fp-autoban-waves-730d`.
- No address reaches the archive: every IP becomes `h:` plus an HMAC whose key is random, lives
  only in the pod's memory and changes every UTC day (and on restart), so minutes of one day join
  and nothing older is reversible. That is why it may outlive the 90 day PII retention of Loki.
- Lifecycle rules are bucket config, not Tofu (`tofu/buckets.tf`): GET the whole configuration
  with the `secret/pg-s3` pair, add to it, PUT it back, never PUT a partial one.
- `FingerprintAutobanArchiveFailing` (warning) after six failed writes in a row; the pod keeps
  at most 120 unwritten runs.
- Each archived minute also carries `edge`: the cf-analytics firewall events of the minute
  `FP_EDGE_LAG_SECONDS` (300) before it, weighted by `sampleInterval` and summed per action,
  outcome (`challenged`, `solved`, `bypassed`, `failed`, `blocked`, `skip`, `log`), source, rule,
  HTTP protocol, host, ASN and user agent family, plus the 300 busiest addresses (hashed) with
  their outcomes (about 10 KB a minute). Not scored; the `run` log line carries its totals.

### Replay and tuning

`scripts/fp-replay.py` runs the controller's own code (read from the manifest) offline, minute
by minute, and prints the first minute each candidate appears. It never calls Cloudflare or the
cluster; `list` and `fetch` read the bucket with rclone and the crypt keys from an OpenBao
reader session, `loki` needs `tsh-grafana`.

```bash
scripts/fp-replay.py list waves                                     # wave folders
scripts/fp-replay.py fetch wave 20261105T1727Z ./fp                 # one wave
scripts/fp-replay.py fetch runs 2026-11-05 2026-11-06 ./fp          # runs of a date range
scripts/fp-replay.py loki 2026-11-05T17:20 2026-11-05T17:50 w.jsonl.gz   # before the archive existed
kubectl -n monitoring get cm fp-autoban-state -o jsonpath='{.data}' > state.json   # logged in baseline
scripts/fp-replay.py score --state state.json ./fp/fp-autoban/waves/20261105T1727Z
scripts/fp-replay.py score ./fp/fp-autoban/runs                     # runs carry their own baseline verdicts
scripts/fp-replay.py score --set FP_FIXED_IPS=3 --sweep FP_STRONG_MIN_REQUESTS=10,20,30,60 w.jsonl.gz
```

A threshold change goes into the Deployment env with the replay that justifies it. The pod reads
`autoban.py` at start: after ArgoCD updates the ConfigMap, `kubectl -n monitoring rollout restart
deploy/fp-autoban`.

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
- 504s with origin status 0 and a UA containing "early hints" are Cloudflare synthetics, filter them out
  before reading any 5xx rate.

### Cloudflare analytics (cf-analytics)

Origin logs only what the edge lets through (47 of about 330k bot requests in the 2026-11-05
17:35 UTC wave). `infra/monitoring/extras/pollers/cf-analytics.yaml` (Python, one replica, token
`cloudflare-edge analytics_token`) reads the edge's own record from the GraphQL Analytics API,
which is free on Pro; Logpush is a usage billed subscription and was declined.

Limits of zone `unorouter.com` (`viewer.zones.settings`, read 2026-11-05):

| dataset | max window | retention | page | fields |
| --- | --- | --- | --- | --- |
| `firewallEventsAdaptive` | 30 d | 31 d | 10000 | 40 |
| `firewallEventsAdaptiveGroups` | 1 d | 3 d | 10000 | 30 |
| `httpRequestsAdaptive` | 30 d | 31 d | 10000 | 70 |
| `httpRequestsAdaptiveGroups` | 30 d | 31 d | 10000 | 40 |

Queries: 300 per 5 minutes per user, shared with edge-probe-watch (4 to 7 per 5 minutes). The
poller spends 3 a minute when quiet and caps itself at `CF_MAX_QUERIES_PER_MINUTE` (40); a 429
cools it down 1, 2, 4 up to 15 minutes. No JA3, JA4 or bot score on Pro (`ja3Hash` is refused).
Both Adaptive groups datasets return `count` already weighted: it equals the sum of
`sampleInterval` over the raw rows (7811 for 6560 skip rows, 2026-11-05 18:52). Raw firewall
rows are sampled too (`sampleInterval` 1 to 10 seen) and every count from them is weighted by it.

Every minute, for the window ending 3 minutes ago (`CF_LAG_SECONDS`):

- **`{app="cf-firewall", host, action}`**: every firewall event, one JSON line with the
  Cloudflare field names: `datetime rayName action source ruleId rulesetId description kind
  matchIndex sampleInterval clientIP clientIPClass clientAsn clientASNDescription
  clientCountryName clientRequestHTTPHost clientRequestHTTPMethodName clientRequestHTTPProtocol
  clientRequestScheme clientRequestPath clientRequestQuery clientRefererHost
  httpApplicationVersion userAgent edgeColoName edgeResponseStatus originResponseStatus
  verifiedBotCategory originatorRayName` (empty fields left out). Actions are snake case
  (`managed_challenge_non_interactive_solved`, `managed_challenge_bypassed`). The dataset has no
  TLS fields. The query string has `key`, `token`, `code`, `state` and similar values replaced by
  `[redacted]`. It re-reads the last 2 minutes (`CF_OVERLAP_SECONDS`) and drops events already
  sent by (rayName, source, ruleId, action); a full page is cut at its last second and the read
  continues from there. About 2200 lines a minute on a quiet evening, 98% of them `skip` (the
  logged in browsers rule and the machine surface skips).
- **`{app="cf-http", host}`**: client requests (`requestSource` eyeball) grouped per minute by
  `clientIP clientAsn clientCountryName clientRequestHTTPHost clientRequestHTTPProtocol
  clientSSLProtocol clientTLSKeyExchangeGroup edgeResponseContentTypeName securityAction
  edgeResponseStatus userAgent`, one line per group with `t`, `count`, `visits`,
  `edgeResponseBytes`, `sampleInterval` (`secs` when a full page split the minute). About 1100
  lines a minute.
- **Prometheus** (no addresses, hosts outside `KNOWN_HOSTS` are `other`):
  `cf_http_requests_total{host,protocol,tls,kex,source,status}`,
  `cf_http_requests_by_action_total{host,action,source}`,
  `cf_http_requests_by_content_total{host,content}`, `cf_http_visits_total{host}`,
  `cf_http_client_addresses`, `cf_firewall_events_total{host,action,source}`, and for the
  poller itself `cf_analytics_rows_total`, `cf_analytics_rows_per_minute`,
  `cf_analytics_pages_total`, `cf_analytics_splits_total`, `cf_analytics_truncated_total`,
  `cf_analytics_queries_total{result}`, `cf_analytics_rate_limited_total`,
  `cf_analytics_loki_lines_total`.
- **Alerts**: `CfAnalyticsStale` (a dataset 15 minutes without a good run or 20 minutes behind),
  `CfAnalyticsMissing`, `CfAnalyticsFailing`, `CfAnalyticsRateLimited`, `CfAnalyticsTruncated`
  (info). Run log: `{namespace="monitoring", app="cf-analytics"} |= "cf-analytics"`.

Behavior signals (Loki keeps at most 500 series per query, so per address queries need `topk`):

```logql
# assets per document per address: a browser loads tens of js, css and images per html page
topk(20, sum by (clientIP) (sum_over_time({app="cf-http", host="unorouter.com"} | json | edgeResponseContentTypeName!="html" | unwrap count [10m]))
  / sum by (clientIP) (sum_over_time({app="cf-http", host="unorouter.com"} | json | edgeResponseContentTypeName="html" | unwrap count [10m])))
# HTTP protocol and key exchange mix: Chrome 131+ offers X25519MLKEM768 and speaks h2 or h3
sum by (clientRequestHTTPProtocol, clientTLSKeyExchangeGroup) (sum_over_time({app="cf-http"} | json | userAgent=~".*Chrome/1[3-9][0-9].*" | unwrap count [10m]))
# requests per address and per user agent
topk(20, sum by (clientIP) (sum_over_time({app="cf-http"} | json | unwrap count [5m])))
topk(20, sum by (userAgent) (sum_over_time({app="cf-http"} | json | unwrap count [5m])))
# challenges issued, solved and bypassed (a clearance cookie from an earlier solve)
sum by (action) (sum_over_time({app="cf-firewall", action=~".*challenge.*"} | json | unwrap sampleInterval [1h]))
# addresses challenged that never solved
topk(20, sum by (clientIP) (count_over_time({app="cf-firewall", action="managed_challenge"} | json [1h])))
```

fp-autoban reads `{app="cf-firewall"}` as its edge input (see its Archive section).
