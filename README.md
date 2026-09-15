# infra

unorouter revenue stack. Three Talos Linux control planes on Hetzner (node11, node12, node13,
nbg1, cx43) on their own WireGuard mesh, no provider network, no SSH; Cilium without kube-proxy,
ArgoCD app-of-apps, CloudNativePG with PITR to Hetzner Object Storage, OpenBao, ESO, cloudflared,
kube-prometheus-stack, Loki.

Everything enters through the Cloudflare tunnel. Two firewalls in series allow Tailscale, the
WireGuard mesh and ICMP, nothing else: Hetzner's in front of the NIC and Talos's own on the
node (`talos/patches/firewall.yaml`), which alone protects a node outside Hetzner. Every daily action is a named, expiring Teleport session;
nothing standing lives on a laptop.

```sh
export KUBECONFIG=~/.kube/teleport-unorouter.yaml   # systemd --user unit tsh-kube
kubectl get nodes
```

| Topic | |
| --- | --- |
| [Access and break-glass](docs/access.md) | kubectl, psql, OpenBao, nodes, Teleport, what to do when SSO is down |
| [Operations](docs/operations.md) | DNS, tofu, node disk, gotchas, deploying a service, pod isolation, upgrading |
| [Monitoring](docs/monitoring.md) | rules, pollers, responders, logs, the Cloudflare edge |
| [DR runbook](docs/dr.md) | backups, rebuild from nothing, node swap, quorum loss, switchover |
| [Nodes](talos/README.md) | machine configs, image, adding a node |
| [incidents/](incidents/) | post-mortems |
