# Monitoring and alerting

kube-prometheus-stack in `monitoring` (local-path PVCs; a PVC pinned to a dead node stays Pending
forever, delete PVC+PV). `infra/monitoring/extras/` is applied recursively and grouped by job:
`alerting/` (Alertmanager routing, rules, ntfy-bridge, the edge-mode and canary-quarantine
responders), `pollers/` (CronJobs that read external APIs and SQL), `scrape/` (scrape targets,
blackbox, the CNPG metric queries),
`grafana/` (dashboards, datasource); network policies, secrets and the s3-gateway stay at the top.
Rules: `alerting/rules-unorouter.yaml` (platform, each from a real incident) and
`alerting/rules-security.yaml` (account takeover, chargebacks, guest abuse), the latter fed by SQL
over the gateway's audit rows in `scrape/cnpg-security-queries.yaml`.

- **Log alerts are LogQL rules** in `infra/loki/logql-rules.yaml`, evaluated by Loki's ruler and
  sent to the same Alertmanager, same routes. Groups: `pgaudit` (non-app role touching an audited
  table), `openbao` (root policy in use pages; non-routine activity digests), `teleport` (role,
  connector or user change pages; SSO connector broken pages; logins, failed logins and db admin
  sessions digest), `dex` (org refusals and logins), `k8s-audit` (human and unknown actors:
  `K8sPodExec`, `K8sSecretRead`, `K8sSecurityConfigurationChanged` critical, `K8sUnexpectedAccess`
  warning; the owner's own Teleport identity `0-don` gets the same alert as a 🔵 info digest,
  never a page). Every rule groups by the actor and strips source ports so one session is one
  alert; the matching log lines are one Explore click away in Grafana.
- **Pollers** (`pollers/`) read what is not a log: `cloudflare-audit-watch` and
  `ghcr-visibility-watch` poll APIs, `image-secret-scan` scans image layers, `pat-audit-archive`
  copies PAT change rows from Postgres into the locked bucket. They speak only to Alertmanager
  through `pollers/watch-lib.yaml` (`notify.digest` for a severity `info` digest, `notify.alert`
  for a critical finding). No poller holds the Discord webhook.
- **Responders** are Alertmanager webhook receivers, one Deployment each: `alerting/edge-mode.yaml`
  flips the Cloudflare zone into attack mode on `CloudflaredStreamFlood`; `alerting/canary-quarantine.yaml`
  gets every pod create in `services` (Loki rule `K8sCanaryWorkload`, severity none), checks the
  pod spec for the honeytoken Secret `credential-canary-v1`, logs a `SECURITY_EVIDENCE` line and
  posts its own critical alert, and with `AUTO_QUARANTINE=true` labels the pod and creates an
  egress deny policy. Detect in a rule, route in Alertmanager, act in a responder: a new
  automation is a rule plus a small Deployment, never a log tailer.
- **System identities** have no allowlist file any more. The Loki rule `K8sSecretRead` (system
  half) pages when a service account reads a Secret outside its own namespace; kubelets are bounded
  by the apiserver's NodeRestriction and platform controllers are one regex in the rule. A new
  cross namespace reader is one regex edit in `infra/loki/logql-rules.yaml`.
- **Discord and the phone both go through `alerting/ntfy-bridge.yaml`** (`/discord`, `/alert`): embeds
  are coloured by severity (🔴 critical, 🟠 warning, 🔵 info, ✅ resolved), which Alertmanager's own
  Discord notifier cannot do. The bridge logs one line per delivery with the Discord status code.
- **Logs**: Vector (DaemonSet, `infra/loki/values-vector.yaml`) tails `/var/log/pods`, the
  kube-apiserver audit files and the Hubble export on every node. Raw lines go to Loki (single
  binary on node9, `infra/loki/values-loki.yaml`, app `apps/loki.yaml`), which stores chunks and
  index through the s3-gateway in `unorouter-loki`, 90 days, compactor owned. A sanitized subset
  (audit without URIs, bodies or annotations; Hubble flows; the openbao, gateway, bot, postgres
  and teleport security records; the responder's lines) goes write once into the locked
  `unorouter-logs` under `vector/<source>/node=<node>/date=<day>/`, acknowledged disk buffer on
  `/var/lib/vector`. Labels are only `namespace, pod, container, node, app, stream` (audit:
  `job="k8s-audit", node`); everything else is a query-time parser. Grafana datasource `loki`
  and the Logs dashboard; start with `{namespace="services"}` or
  `{job="k8s-audit"} | json | verb="create"`. Gateway logs carry IPs and emails, so the 90 days are
  also the PII retention for logs; Grafana is the only reader and sits behind Teleport. The ruler
  runs the LogQL rules in `infra/loki/logql-rules.yaml` (ConfigMaps labelled `loki_rule: "1"`,
  alerts to the same Alertmanager, same routes). Vector health is `infra/loki/rules.yaml`: the
  archive sink's discards and errors page, the rest is Discord.
- **Routing is drop-by-default**: root receiver `null`, only critical/warning reach Discord;
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **`CloudflaredStreamFlood`** is the L7 attack signal: pages, and fires `edge-mode`, which flips
  the zone to the attack ruleset and back 30 min after resolve.
- etcd needs `--etcd-expose-metrics=true` on every server; targets are a static IP list in
  `scrape/etcd.yaml`, update on every node swap.
- Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients, blackbox config and the ConfigMap code of ntfy-bridge, edge-mode and
  canary-quarantine are read at boot: `rollout restart` the deployment after a change, ArgoCD
  only updates the ConfigMap.
- A duplicate group name in `alerting/rules-unorouter.yaml` fails the SSA diff and silently stops the whole
  monitoring app syncing; check `.status.conditions` before suspecting drift.
- Prometheus, Alertmanager, Grafana, blackbox and kps-operator are still pinned to node9 by
  `nodeSelector`; that node is the single point of failure for monitoring.
