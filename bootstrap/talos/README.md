# Talos nodes

The cluster runs Talos Linux: no shell, no SSH, no package manager. A node is the Image
Factory snapshot plus one rendered machine config, and everything about it is in this
directory. Kubernetes above the OS is unchanged: Cilium, ArgoCD and the apps come from `apps/`.

| File | Purpose |
| --- | --- |
| `schematic.yaml` | Image Factory schematic: `qemu-guest-agent`, `tailscale`. Schematic id `7d4c31cb...` |
| `upload-image.sh <talos version>` | builds the Hetzner snapshot from the factory image (one temporary rescue server), labels it `os=talos` |
| `talconfig.yaml`, `patches/` | talhelper input: three control plane nodes, KubePrism, no kube-proxy, no bundled CoreDNS, the k3s pod and service CIDRs, audit policy, Pod Security exemptions, etcd metrics, sysctls, kubelet swap posture, the user volume for local-path, 4 GiB swap, Tailscale extension |
| `spare-join.sh <server> <node>` | turns a parked spare into a node: rename, rebuild to the snapshot, apply the config over the maintenance API |
| `../../secrets/talos.sops.yaml` | the cluster secrets (`talhelper gensecret`), break-glass age key only |

Gitignored: `talsecret.yaml` (decrypted secrets), `clusterconfig/` (rendered machine configs and
the talosconfig), kubeconfigs, snapshots. Nothing rendered is ever committed.

## Rendering

```sh
sops -d secrets/talos.sops.yaml > bootstrap/talos/talsecret.yaml
cd bootstrap/talos && TS_AUTHKEY=$(bao kv get -field=talos_auth_key secret/tailscale) talhelper genconfig
wc -c clusterconfig/*.yaml      # Hetzner caps user data at 32768 bytes
```

The Tailscale key is tagged `tag:node`, reusable, pre-authorised and pre-signed for Tailnet
Lock (`tailscale lock sign <key>` on a signer), so a node joining with it is trusted on
arrival. Rotate it in the admin console, sign, `bao kv patch secret/tailscale talos_auth_key=@-`.

## A new node

The sniper (`bootstrap/hetzner-snipe.sh`) parks a spare that boots the snapshot with no
config and waits in maintenance mode behind the node firewall. Give it a name in
`talconfig.yaml` (next number, its private IP as Hetzner assigned it), render, then:

```sh
./spare-join.sh unorouter-spare-nbg1-1 unorouter-node14
```

Three minutes later `tailscale status` lists it and `talosctl -n unorouter-node14.taild195fa.ts.net
health` passes; it is an etcd member and a Ready node. Add the tofu block and import it
(`tofu/node.tf`), add its private IP to `infra/monitoring/extras/scrape/etcd.yaml`, and to the
SANs here.

Removing a node: evacuate (the node swap runbook in `bootstrap/dr/README.md`), then
`talosctl -n <node> reset` (a graceful reset leaves etcd itself), `kubectl delete node`, the
tofu targeted destroy. `talosctl etcd remove-member` is only for a node that is already gone;
deleting a member without either leaves etcd without a leader (seen on the proof).

## Operating

```sh
export TALOSCONFIG=bootstrap/talos/clusterconfig/talosconfig     # after rendering
talosctl -n unorouter-node11.taild195fa.ts.net dashboard           # what a shell used to be
talosctl -n <node> logs kubelet | services | dmesg
talosctl -n <node> get volumestatus                                # partitions, the user volume, swap
talosctl -n <node> read /var/log/audit/kube/audit.log
talosctl -n <node> etcd status
```

Upgrades (Renovate bumps the pins in `talconfig.yaml`, the steps are by hand,
`docs/versions.md`): Talos one node at a time, `talosctl -n <node> upgrade --image
factory.talos.dev/installer/<schematic>:<version>` (A/B image, rolls back if the new one does
not boot, the disk is never wiped); Kubernetes once, `talosctl -n <node11> upgrade-k8s --to
<version>`, which walks every node.

Machine config changes: edit here, render, `talosctl -n <node> apply-config -f
clusterconfig/unorouter-<node>.yaml` (most settings apply live, the output says when a reboot
is needed). Never `talosctl edit mc` by hand: the next render would undo it.

## etcd

`infra/talos/etcd-backup.yaml` snapshots every member nightly into
`unorouter-backups/etcd/<node>/<date>.snapshot` through the s3-gateway, with a talosconfig
that holds only the `os:etcd:backup` role. Recovery from total control plane loss and from
quorum loss are in `bootstrap/dr/README.md`: reset the others, `talosctl bootstrap
--recover-from <snapshot>` on one, the rest rejoin. Proven twice on the spares before the
migration (2026-09-10).

## Rules learned on the proof

- Hetzner boots the snapshot straight into an installed Talos; a config from user data is
  applied at first boot, one from the maintenance API on a rebuilt server the same way.
- Without `VolumeConfig EPHEMERAL maxSize` the EPHEMERAL partition takes the whole disk at
  install and the swap and user volumes fail with "not enough space". Install time only.
- The apiserver audit log is outside the kubelet's mount namespace until
  `machine.kubelet.extraMounts` binds it (`patches/machine.yaml`); the directory is
  `nobody:nobody 0700`, so Vector needs `DAC_READ_SEARCH`.
- Pod Security is `baseline` cluster wide; the hostPath namespaces are exempted in
  `patches/cluster.yaml`, not labelled in git.
- Interfaces are `eth0` (public) and `eth1` (private network), configured by the platform and
  DHCP; nothing static in the config.
- KubePrism (`localhost:7445`) is what Cilium and every in-cluster client use; the cluster
  endpoint in `talconfig.yaml` only matters to talosctl and to the first bootstrap.
