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

Servers boot the Talos snapshot (`bootstrap/talos/upload-image.sh`) with their rendered machine
config as user data, so a fresh apply brings the OS and Kubernetes up; `./scripts/dr.sh
bootstrap` then installs Cilium, ArgoCD and the root app from git. Prerequisites: the
break-glass age key (VeraCrypt volume plus Bitwarden, loss = secrets unrecoverable), Hetzner
token, the Hetzner Object Storage key (`tofu/.env`), talhelper and talosctl.

### Node disk

Images are the only reclaimable chunk; the rest of the disk is live local-path data on the
user volume (`bootstrap/talos/patches/volumes.yaml`). Kubelet `imageGCHighThresholdPercent: 70`
/ `low: 55` is set in `bootstrap/talos/patches/machine.yaml`. There is no shell to prune by
hand: `talosctl -n <node> get volumestatus` shows the partitions, `talosctl -n <node> image ls`
the images.

`NodeDiskFillingUp` at 75% means GC already ran and the growth is real data.

## Non-negotiable gotchas

- All nodes are Talos control planes; etcd and the kubelet are pinned to `10.100.1.0/24`
  (`patches/cluster.yaml`, `patches/machine.yaml`). Cilium and every in-cluster client reach the
  apiserver through KubePrism (`localhost:7445`).
- CNPG uses the Barman Cloud PLUGIN. A test-restore from the real bucket is a hard gate.
- ACME HTTP-01 can never reach an origin behind the tunnel: use the `letsencrypt-dns`
  ClusterIssuer (DNS-01).
- Node ops manual, one node per apply, plan reviewed (a both-nodes `-replace` = 34 min DB outage).
- new-api master stays `replicas: 1`. CNPG primaries drift on failover: read
  `status.currentPrimary` every time.
- Cilium is `infra/cilium` and ArgoCD is the upstream install in `bootstrap/argocd`, both
  applied by `dr.sh bootstrap` before ArgoCD exists and owned by git afterwards. Pod Security is
  `baseline` cluster wide; a workload that needs more gets its own labelled namespace
  (`infra/services/uno-import.yaml`), never a wider exemption.
- ArgoCD polls every 120s + up to 60s jitter with a 3-min repo cache, so a push lands 1.5 to 6
  minutes later. There is no webhook. A CNPG or ScrapeConfig field defaulted by a webhook inside
  an atomic list reads OutOfSync forever: state the default in the manifest.
- Firewall (`tofu/firewall.tf`) allows Tailscale UDP + ICMP only. Never open 22/6443 without a
  source IP and a removal step.
- Org hardening that must stay: base repo permission `none`, member repo creation OFF (the
  ApplicationSet deploys any org repo with `k8s/`), contributions via fork PRs, two org owners.
- Vector keeps its log checkpoints and disk buffers under `/var/lib/vector` on each node; a
  node rebuild starts it from the end of every file.
