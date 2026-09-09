# infra

unorouter revenue stack. 3-node k3s HA on Hetzner (node8 hel1, node9 nbg1, node10 hel1, cx43,
embedded etcd, private net 10.100.0.0/16), Cilium without kube-proxy, ArgoCD app-of-apps,
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
| [Pinned versions](docs/versions.md) | what to bump and where |
| [Cluster operations](docs/cluster.md) | tofu, DNS, node disk, non-negotiable gotchas |
| [DR runbook](bootstrap/dr/README.md) | rebuild from nothing |
| [incidents/](incidents/) | post-mortems |
