# Monitoring and alerting

kube-prometheus-stack, Loki and blackbox run on node12 (`nodeSelector` on the label
`unorouter.com/monitoring`, local-path PVCs; a PVC pinned to a dead node stays Pending, delete
PVC and PV). `infra/monitoring/extras/` is applied recursively: `alerting/` (Alertmanager
routing, rules, ntfy-bridge, responders), `pollers/` (CronJobs reading external APIs and SQL),
`scrape/` (targets, blackbox, the CNPG metric queries), `grafana/` (dashboards, datasource).

- **Rules**: `alerting/rules-unorouter.yaml` (platform, each from a real incident) and
  `alerting/rules-security.yaml` (account takeover, card testing, chargebacks, guest abuse), fed by
  SQL over the gateway's tables in `scrape/cnpg-security-queries.yaml`.
- **Log alerts** are LogQL rules in `infra/loki/logql-rules.yaml` (ConfigMaps labelled
  `loki_rule: "1"`, Loki's ruler, same Alertmanager). Groups: `pgaudit`, `openbao` (root policy
  in use pages), `teleport` (role, connector or user change pages), `dex`, `k8s-audit`
  (`K8sPodExec`, `K8sSecretRead`, `K8sSecurityConfigurationChanged` critical,
  `K8sUnexpectedAccess` warning; the owner's own identity `0-don` gets an info digest, never a
  page). Rules group by actor and strip source ports, one session is one alert. `K8sSecretRead`
  also pages when a service account reads a Secret outside its namespace; platform controllers
  are one regex in the rule.
- **Pollers** (`cloudflare-audit-watch`, `ghcr-visibility-watch`, `image-secret-scan`,
  `pat-audit-archive`) speak only to Alertmanager through `pollers/watch-lib.yaml`
  (`notify.digest` info, `notify.alert` critical). No poller holds the Discord webhook.
- **Responders** are Alertmanager webhook receivers, one Deployment each: `edge-mode` flips the
  Cloudflare zone into attack mode on `CloudflaredStreamFlood` and back 30 min after resolve.
  Detect in a rule, route in Alertmanager, act in a responder; never a log tailer.
- **Routing is drop-by-default**: root receiver `null`; critical and warning reach Discord
  through `alerting/ntfy-bridge.yaml` (severity-coloured embeds, one log line per delivery),
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **Logs**: Vector (DaemonSet, `infra/loki/values-vector.yaml`) tails `/var/log/pods`, the
  apiserver audit files and the Hubble export. Raw lines go to Loki (`infra/loki/values-loki.yaml`),
  chunks and index through the s3-gateway in `unorouter-loki`, 90 d, which is also the PII
  retention (gateway logs carry IPs and emails; Grafana behind Teleport is the only reader). A
  sanitized subset goes write-once into the locked `unorouter-logs`. Labels are only
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
