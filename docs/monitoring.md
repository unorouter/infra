# Monitoring and alerting

kube-prometheus-stack in `monitoring` (local-path PVCs; a PVC pinned to a dead node stays Pending
forever, delete PVC+PV). `infra/monitoring/extras/` is applied recursively and grouped by job:
`alerting/` (Alertmanager routing, rules, ntfy-bridge, edge-mode), `watchers/` (the security
watchers and the evidence archive), `scrape/` (scrape targets, blackbox, the CNPG metric queries),
`grafana/` (dashboards, datasource); network policies, secrets and the s3-gateway stay at the top.
Rules: `alerting/rules-unorouter.yaml` (platform, each from a real incident) and
`alerting/rules-security.yaml` (account takeover, chargebacks, guest abuse), the latter fed by SQL
over the gateway's audit rows in `scrape/cnpg-security-queries.yaml`.

- **Watchers** (`watchers/*-watch.yaml`, CronJobs every 5 min plus the `k8s-audit-watch` DaemonSet)
  speak only to Alertmanager through `watchers/watch-lib.yaml` (`notify.digest` for a severity
  `info` digest: Discord only, deduplicated by a hash of its text, never RESOLVED; `notify.alert`
  for a critical finding: Discord plus the phone). No watcher holds the Discord webhook. Pages:
  non-routine Secret reads and any `exec` (`K8sSecretRead`, `K8sPodExec`), OpenBao root use
  (`OpenBaoRootUsed`), Teleport role/connector/user changes (`TeleportPrivilegeChange`), a public
  GHCR package (`PublicPackageExposed`), secret material in an image (`ImageSecretLeak`). Digests:
  pgaudit rows from a non-app role, Cloudflare account audit, OpenBao non-routine activity, SSO
  logins. Named Teleport operators (`NAMED_USERS`) go into one daily digest instead, since
  Teleport records their sessions. A new platform component that reads Secrets belongs in
  `ROUTINE_USERS`, not in silence.
- **Routing is drop-by-default**: root receiver `null`, only critical/warning reach Discord;
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **`CloudflaredStreamFlood`** is the L7 attack signal: pages, and fires `edge-mode`, which flips
  the zone to the attack ruleset and back 30 min after resolve.
- etcd needs `--etcd-expose-metrics=true` on every server; targets are a static IP list in
  `scrape/etcd.yaml`, update on every node swap.
- Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients and blackbox config are read at boot: `rollout restart` the deployment.
- A duplicate group name in `alerting/rules-unorouter.yaml` fails the SSA diff and silently stops the whole
  monitoring app syncing; check `.status.conditions` before suspecting drift.
- Prometheus, Alertmanager, Grafana, blackbox and kps-operator are still pinned to node9 by
  `nodeSelector`; that node is the single point of failure for monitoring.
