# Cluster operations

## DNS

`*.unorouter.com` CNAME to the tunnel covers every host. New hostname: add a `hostname:` rule to
[cloudflared.yaml](../infra/cloudflared/cloudflared.yaml), push, then `kubectl -n cloudflared
rollout restart deploy/cloudflared` (config read at startup only).

## tofu

`tofu/.env` (gitignored) exports every `TF_VAR_*`; the state is client-side encrypted.

```sh
cd tofu && tofu init
set -a; source .env; set +a
tofu plan    # read before apply; server ops one node at a time
tofu apply   # manual only
```

Cloud-init writes k3s auto-deploy manifests (Cilium + ArgoCD + root app), so a fresh apply brings
the stack up from git. Prerequisites: the break-glass age key (VeraCrypt volume plus Bitwarden,
loss = secrets unrecoverable), Hetzner token, the Hetzner Object Storage key (`tofu/.env`).

### Node disk

Images are the only reclaimable chunk; the rest of the 150G root is live local-path data. Kubelet
`image-gc-high-threshold=70` / `low=55` is set in `tofu/cloud-init*.tftpl` AND
`/etc/rancher/k3s/config.yaml` on each node (keep in sync). Manual prune:

```sh
/var/lib/rancher/k3s/data/current/bin/crictl -r unix:///run/k3s/containerd/containerd.sock rmi --prune
```

`NodeDiskFillingUp` at 75% means GC already ran and the growth is real data.

## Non-negotiable gotchas

- All nodes are k3s SERVERS with `--advertise-address=<private-ip>`. Cilium
  `k8sServiceHost: 127.0.0.1` is valid only while that holds.
- After changing a `--node-ip`: restart the cilium DaemonSet.
- CNPG uses the Barman Cloud PLUGIN. A test-restore from the real bucket is a hard gate.
- ACME HTTP-01 can never reach an origin behind the tunnel: use the `letsencrypt-dns`
  ClusterIssuer (DNS-01).
- Node ops manual, one node per apply, plan reviewed (a both-nodes `-replace` = 34 min DB outage).
- new-api master stays `replicas: 1`. CNPG primaries drift on failover: read
  `status.currentPrimary` every time. Keep the primary in hel1, next to the gateway.
- **The Cilium and ArgoCD HelmChart CRs exist only in the cluster.** Upgrade by patching the live
  CR (`spec.valuesContent`) AND `tofu/cloud-init.yaml.tftpl`, the DR copy. Both carry
  `failurePolicy: abort` and ArgoCD keeps its CRDs, because a re-applied bootstrap file with the
  default `reinstall` policy once uninstalled ArgoCD and every Application vanished.
- ArgoCD polls every 120s + up to 60s jitter with a 3-min repo cache, so a push lands 1.5 to 6
  minutes later. There is no webhook. A CNPG or ScrapeConfig field defaulted by a webhook inside
  an atomic list reads OutOfSync forever: state the default in the manifest.
- Firewall (`tofu/firewall.tf`) allows Tailscale UDP + ICMP only. Never open 22/6443 without a
  source IP and a removal step.
- Org hardening that must stay: base repo permission `none`, member repo creation OFF (the
  ApplicationSet deploys any org repo with `k8s/`), contributions via fork PRs, two org owners.
- Leftover node state from retired agents, safe to `rm -rf` on each node: `/var/lib/alloy` (Alloy
  positions) and `/var/lib/unorouter-evidence` (the k8s-audit-watch sqlite queue). Vector keeps its
  checkpoints and buffers under `/var/lib/vector`.
