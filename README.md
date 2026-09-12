# infra

unorouter revenue stack. Three Talos Linux control planes on Hetzner (node11, node12, node13,
nbg1, cx43, private net 10.100.1.0/24, KubePrism, no SSH, machine configs in `bootstrap/talos`),
Cilium without kube-proxy, ArgoCD app-of-apps,
CloudNativePG with PITR to Hetzner Object Storage, OpenBao, ESO, cloudflared, kube-prometheus-stack.

Everything enters through the Cloudflare tunnel. The Hetzner firewall allows only Tailscale UDP
and ICMP. Every daily action runs as a named, expiring Teleport session; nothing standing lives
on a laptop.

```sh
export KUBECONFIG=~/.kube/teleport-unorouter.yaml   # systemd --user unit tsh-kube
kubectl get nodes
```

| Topic | |
| --- | --- |
| [Access and break-glass](docs/access.md) | kubectl, psql, OpenBao, node shell, what to do when SSO is down |
| [Deploying a service](docs/deploying.md) | a repo with `k8s/` deploys itself |
| [Pod isolation](docs/network-policies.md) | default-deny everywhere, how to add a workload |
| [Monitoring](docs/monitoring.md) | rules, watchers, what pages |
| [Cloudflare edge](docs/edge.md) | rulesets, attack mode |
| [Backups](docs/backups.md) | Postgres PITR, Velero, OpenBao snapshots |
| [Upgrading](docs/versions.md) | Renovate holds the index, the steps it cannot take |
| [Cluster operations](docs/cluster.md) | tofu, DNS, node disk, non-negotiable gotchas |
| [DR runbook](bootstrap/dr/README.md) | rebuild from nothing |
| [incidents/](incidents/) | post-mortems |
