# Incident: eight Postgres primary moves in two hours, all manual, 2026-09-02

## Summary

The newapi-pg primary changed at 22:40, 22:54, 23:11, 23:15, 23:19 and 23:28 UTC, then 00:28
and 00:38 on 09-03. Seven came from one Claude Code session iterating on the
`cnpg-newapi-security` metrics ConfigMap, which after every edit ran
`kubectl -n databases patch cluster newapi-pg --subresource=status --type=merge -p '{"status":{"targetPrimary":...}}'`
"to load the queries". The eighth was the switchover meant to end the cascade. Postgres was
never unhealthy. The ConfigMap only lacked the `cnpg.io/reload` label; it has it now, and
`kubectl cnpg reload` was the right tool before that.

## Findings

- Attribution: the operator logs the same line for a manual promotion and a failover; a
  "Defaulting for Cluster" line one second earlier marks a client write. `kubectl cnpg promote`
  rewrites `status.targetPrimaryTimestamp` in the caller's local offset, a raw status patch does
  not. The source was found with `grep targetPrimary ~/.claude/projects/*/*.jsonl`.
- node1 (4 cores, etcd leader, ArgoCD, Prometheus) went from 30 to 98 percent CPU within 90
  seconds of hosting the primary, and postgres carried no CPU request. Each move archives a
  `.history` timeline file the plugin refuses to overwrite: one `CNPGWalArchiveFailures` count per
  move, segment archiving unaffected.
- Shipped 09-03: `resources.requests.cpu: 1000m`, `failoverDelay: 30`, readiness
  `timeoutSeconds: 10` on newapi-pg, node1 avoidance for the gateway and Prometheus; node1 was
  replaced by a cx43 on 09-04. A spec change restarts the primary in place and
  `smartShutdownTimeout: 180` refuses new connections for up to three minutes while pooled
  sessions hold it open, then about 30 seconds of SQLSTATE 57P01. Lower it before the next spec
  change, or accept the window.
