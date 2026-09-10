# Talos proof on the parked spares

Decision 2026-09-10: the next cluster runs Talos Linux. This directory holds the proof that
was run on the two parked cx43 spares before any migration work; production, the k3s cluster
and every other path in this repo were untouched. The comparison that led here is in the
session plan of 2026-09-10; the short version: Talos removes the host OS as a thing to prepare,
k0s would still have had an Ubuntu underneath, k3s bundles what we disable.

## What is here

| File | Purpose |
| --- | --- |
| `schematic.yaml` | Image Factory schematic: `qemu-guest-agent`, `tailscale` |
| `upload-image.sh <talos version>` | builds the Hetzner snapshot from the factory image (one temporary rescue server), prints the snapshot id |
| `talconfig.yaml`, `patches/` | talhelper input: two control plane nodes, KubePrism, no kube-proxy, k3s pod and service CIDRs, audit policy, etcd metrics, sysctls, kubelet swap posture, user volume for local-path, 4 GiB swap partition, Tailscale extension |
| `poc-cilium-values.yaml` | `infra/cilium/values.yaml` plus the Talos keys (KubePrism address, cgroup, capabilities) |
| `poc-restore.yaml` | scratch restore of bot-pg through a one replica gateway copy with a self signed cert, read only against the bucket |

Gitignored: `talsecret.yaml` (talhelper secrets), `clusterconfig/` (rendered machine configs
and talosconfig), kubeconfigs, snapshots. Nothing rendered is ever committed.

## Procedure as run

1. `talosctl` v1.13.10, `talhelper`, `hcloud-upload-image` in `~/.local/bin`.
2. `./upload-image.sh v1.13.10` (needs a free server slot): snapshot `430137253`.
3. Tailscale auth key: admin console, reusable, pre-approved, `tag:node`, 7 days, revoked
   after the proof. `talhelper gensecret > talsecret.yaml`,
   `TS_AUTHKEY=... talhelper genconfig`.
4. Spares deleted and recreated by API from the snapshot with the rendered machine config as
   user data (same names, private IPs 10.100.1.1 and 10.100.1.5, node firewall, cluster
   network, no SSH key). The sniper on netcup was stopped for the duration.
5. `talosctl --talosconfig clusterconfig/talosconfig -e <tailnet name> -n <tailnet name> bootstrap`
   on node 1, `talosctl kubeconfig`.
6. Cilium: `helm install cilium cilium/cilium --version 1.20.1 -n kube-system -f poc-cilium-values.yaml`.
7. local-path-provisioner into `local-path-storage` (privileged), path `/var/mnt/local-path-provisioner`.
8. cert-manager, CNPG operator, Barman plugin from the pinned URLs in `infra/`, secrets by hand
   from OpenBao, `poc-restore.yaml`, wait for the cluster, run the check Job.
9. Vector with the audit source on `/var/log/audit/kube`, console sink.
10. `talosctl etcd snapshot`, then both servers deleted and recreated from the snapshot with the
    corrected user data, `bootstrap --recover-from` on node 1, node 2 joined.
11. Teardown: servers deleted (the sniper rebuys Ubuntu spares), tailnet devices removed, ACL
    reverted, proof auth key and API token revoked, rendered configs and secrets deleted
    locally. The Hetzner snapshot `430137253` stays: it is the migration's image.

## Findings (2026-09-10)

- Hetzner boots the factory snapshot straight into an installed Talos; the machine config from
  user data is applied at first boot, no install step, no ISO. Both nodes were on the tailnet
  about three minutes after the create call.
- Tailnet Lock holds new nodes until signed: `tailscale lock sign nodekey:<key>` from the
  laptop for each, then they are reachable. The Tailscale ACL needed `50000` added to the
  `2-don@github -> tag:node` grant for talosctl (done live for the proof, reverted after).
- Interface names on Hetzner are `eth0` (public) and `eth1` (private network), both configured
  by the hcloud platform and DHCP; nothing static in the machine config. The private IP must
  be passed at server create (`networks[].ip`), otherwise Hetzner assigns the lowest free one.
- Without a `VolumeConfig EPHEMERAL maxSize` the EPHEMERAL partition takes the whole disk at
  install and the swap and user volumes fail with "not enough space". The cap is install time
  only, so it belongs in the initial user data (added to `patches/volumes.yaml`).
- `local-path-provisioner` on `/var/mnt/local-path-provisioner` binds PVCs even without the
  user volume (the path is on EPHEMERAL); the user volume only matters for sizing.
- The apiserver audit log `/var/log/audit/kube` is invisible to the kubelet's mount namespace:
  a hostPath on it fails with "is not a directory" until the kubelet gets an `extraMounts`
  bind for it (added to `patches/machine.yaml`, applied live without a reboot).
- Cilium 1.20.1 with `k8sServiceHost: localhost`, `k8sServicePort: 7445` (KubePrism) and the
  Talos cgroup and capability keys: nodes Ready in under 90 s, KubeProxyReplacement true,
  Hubble relay up, cluster health 2/2.
- CNPG 1.30 plus Barman plugin 0.15 restored `bot-pg` v7 through a one replica gateway copy
  with a self signed CA pinned as `endpointCA`: base backup plus WAL replay, 17 populated
  tables, gateway cache "to upload 0" the whole time (read only).
- Pod Security: Talos enforces `baseline` cluster wide and warns on `restricted`; namespaces
  with hostPath or root pods (`monitoring`, `local-path-storage`) need the `privileged` label.
- The audit directory is `nobody:nobody 0700` (Talos runs the apiserver as nobody). Vector as
  root with every capability dropped gets "Permission denied" on the glob; `DAC_READ_SEARCH`
  added to its capabilities fixes it, after which every secret read shows up with the actor.
- `talosctl etcd snapshot` of the fresh cluster: 15 MB, 904 keys. Total loss test: both servers
  deleted and recreated from the snapshot image with corrected user data, `talosctl bootstrap
  --recover-from poc.snapshot` on the first node, second node joined, both Ready, every
  namespace and PVC object back (PV contents gone, as with any lost node).
- Deleting a member server without `talosctl etcd remove-member` first leaves a two member
  etcd without quorum ("no leader"); the way out was a non graceful reset of the survivor and
  `--recover-from` again. With three nodes one loss keeps quorum; the removal step stays in
  the node swap runbook regardless. Sizing that works on a 160 GB disk: EPHEMERAL max 80 GiB,
  swap 4 GiB, user volume min 40 GiB grow (lands at 69 GB).
