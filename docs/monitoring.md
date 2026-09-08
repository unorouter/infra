# Monitoring and alerting

kube-prometheus-stack in `monitoring` (local-path PVCs; a PVC pinned to a dead node stays Pending
forever, delete PVC+PV). Rules: `extras/rules-unorouter.yaml` (platform, each from a real
incident) and `rules-security.yaml` (account takeover, chargebacks, guest abuse), the latter fed
by SQL over the gateway's audit rows in `cnpg-security-queries.yaml`.

- **Watchers** (`extras/*-watch.yaml`, CronJobs every 5 min plus the `k8s-audit-watch` DaemonSet)
  post to Discord and page on exceptions: non-routine Secret reads and any `exec`
  (`K8sSecretRead`, `K8sPodExec`), OpenBao root use (`OpenBaoRootUsed`), Teleport role/connector/
  user changes (`TeleportPrivilegeChange`), pgaudit rows from a non-app role, Cloudflare account
  audit, GHCR visibility, image-layer secret scans, SSO logins. Named Teleport operators
  (`NAMED_USERS`) go into one daily digest instead, since Teleport records their sessions.
  A new platform component that reads Secrets belongs in `ROUTINE_USERS`, not in silence.
- **Routing is drop-by-default**: root receiver `null`, only critical/warning reach Discord;
  critical also pages the phone via ntfy. Test with `amtool alert add` in the alertmanager pod.
- **`CloudflaredStreamFlood`** is the L7 attack signal: pages, and fires `edge-mode`, which flips
  the zone to the attack ruleset and back 30 min after resolve.
- etcd needs `--etcd-expose-metrics=true` on every server; targets are a static IP list in
  `extras/scrape-etcd.yaml`, update on every node swap.
- Backup freshness reads the `Backup` CRs via kube-state-metrics (the plugin's own metric is 0).
- dex clients and blackbox config are read at boot: `rollout restart` the deployment.
- A duplicate group name in `rules-unorouter.yaml` fails the SSA diff and silently stops the whole
  monitoring app syncing; check `.status.conditions` before suspecting drift.
- Prometheus, Alertmanager, Grafana, blackbox and kps-operator are still pinned to node9 by
  `nodeSelector`; that node is the single point of failure for monitoring.
