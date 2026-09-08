# Pod isolation

All 13 namespaces are default-deny (plain `NetworkPolicy`, empty selector, Ingress+Egress) plus
one `CiliumNetworkPolicy` per workload in `infra/<ns>/networkpolicies.yaml`. A pod reaches only
its own dependencies, and the internet only on the ports its code can dial.

- **Never `toFQDNs` or a DNS L7 rule here**: with socket-LB + vxlan + legacy host routing the
  transparent DNS proxy drops every redirected query (cilium/cilium#46284). Internet egress is
  `toCIDR` where documented, else `toEntities: [world]` on named ports.
- Ports in rules are container ports. The API server is `[host, remote-node, kube-apiserver]`
  (admission webhooks arrive from those). Kubelet probes arrive as `host`.
- Stage with `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled` on every endpoint of the
  namespace BEFORE the policy lands, watch `hubble observe --verdict AUDIT --verdict DROPPED`,
  then disable audit and watch drops again.
- Helm/ArgoCD hook Jobs run under their own ServiceAccount and are enforced from birth: put them
  in a selector first or the sync wedges with the Job stuck on `hook-finalizer`.
- **Run a cluster-wide `hubble observe --verdict DROPPED --since 60m` an hour after any policy
  change.** Clients that only talk on user action (Grafana verifying a JWT, a watcher paging
  Alertmanager) never show up in a quiet 10-minute window; both broke silently that way.
