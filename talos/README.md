# Talos nodes

A node is the Image Factory snapshot plus one rendered machine config. No shell, no SSH, no
package manager; `talosctl` over the tailnet is the whole management path.

| File | |
| --- | --- |
| `schematic.yaml` | Image Factory schematic (`tailscale` only), id `4a0d65c6...`; nodes still run the old `7d4c31cb` image with `qemu-guest-agent` (useless on Hetzner, only enables console password reset) until the next `talosctl upgrade` |
| `talconfig.yaml`, `patches/` | talhelper input; every non-obvious setting is commented where it is set |
| `patches/firewall.yaml` | node firewall, default block; every host port and its clients are listed there |
| `talsecret.sops.yaml` | cluster secrets (`talhelper gensecret`), break-glass key only |
| `talenv.sops.yaml` | `${...}` substitutions: per node `WG_NODE1x_{PRIVATE,PUBLIC,ENDPOINT}`, plus `TS_AUTHKEY` |

`clusterconfig/` (rendered configs, talosconfig) is gitignored, never committed.

## Render

```sh
cd talos && SOPS_AGE_KEY_FILE=/run/media/veracrypt1/unorouter/sops-age-keys.txt talhelper genconfig
wc -c clusterconfig/*.yaml      # Hetzner caps user data at 32768 bytes
```

Apply: `talosctl -n <node> apply-config -f clusterconfig/unorouter-<node>.yaml` (most settings
live, the output says when a reboot is needed). Never `talosctl edit mc`: the next render undoes
it. The Tailscale key is reusable, tagged `tag:node`, pre-signed for Tailnet Lock; rotate in the
admin console, `tailscale lock sign`, `sops set talenv.sops.yaml '["TS_AUTHKEY"]' '"<key>"'`.

## Image, once per Talos version

```sh
ID=$(curl -sf -X POST --data-binary @talos/schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
HCLOUD_TOKEN=... hcloud-upload-image upload \
  --image-url "https://factory.talos.dev/image/$ID/v1.13.10/hcloud-amd64.raw.xz" \
  --architecture x86 --compression xz --location nbg1 \
  --description "Talos v1.13.10 $ID" --labels "os=talos,talos=v1.13.10,schematic=${ID:0:12}"
```

## A new node

Created with its rendered config as user data, nothing else.
A new server can also encrypt `STATE`: add a `VolumeConfig` named `STATE` with the same
`encryption` block as the other volumes in `patches/volumes.yaml` to its config before the
first boot (install time only, the three existing nodes cannot).

1. `openssl genpkey -algorithm X25519` key pair into `talenv.sops.yaml` (`WG_NODE14_PRIVATE`,
   `WG_NODE14_PUBLIC`; no endpoint yet).
2. `talconfig.yaml`: the node14 row (`ipAddress: unorouter-node14.taild195fa.ts.net`,
   `10.200.0.14/24`, peers with the existing endpoints, its SAN); in every existing row a node14
   peer with `publicKey` and `allowedIPs` only. Its public address goes into the `wireguard`
   rule of `patches/firewall.yaml` (until known: `0.0.0.0/0` there, WireGuard never answers
   an unauthenticated packet). A peer without an endpoint is valid: node14
   dials out with keepalive, the others learn its address from the handshake.
3. Render, `apply-config` on each existing node (live).
4. In stock: the entry in `local.nodes` (`tofu/nodes.tf`), `tofu apply`. Sold out: the
   rendered config next to the sniper's env on the VPS, `SNIPE_USER_DATA=<path>`, restart the
   unit; then the `local.nodes` entry and `tofu import 'hcloud_server.node["node14"]' <id>`.
5. Three minutes later `talosctl -n unorouter-node14.taild195fa.ts.net health` passes. Put its
   public address into `talenv.sops.yaml` as `WG_NODE14_ENDPOINT` when convenient and re-apply
   the others; the Hetzner rule follows `local.nodes`.

Removal is the node swap in `docs/dr.md`: `talosctl reset` (graceful, leaves etcd itself),
`kubectl delete node`, targeted destroy. `etcd remove-member` only for a node already gone.

## Operating

```sh
export TALOSCONFIG=talos/clusterconfig/talosconfig
talosctl -n <node> dashboard | logs kubelet | dmesg | etcd status
talosctl -n <node> get volumestatus                   # partitions, user volume, swap
talosctl -n <node> read /var/log/audit/kube/audit.log
talosctl -n <node> upgrade --image factory.talos.dev/installer/<schematic>:<version>   # one node at a time, A/B
talosctl -n <node11> upgrade-k8s --to <version>                                      # walks every node
```

Nightly etcd snapshots: `infra/talos/etcd-backup.yaml` into `unorouter-backups/etcd/<node>/`;
recovery is in `docs/dr.md`.

## Not written anywhere else

- Any explicit link in the machine config switches off Talos's default DHCP, so `eth0` is
  listed with `dhcp: true` on purpose next to `wg0`.
- The kubelet does not retry a rejected static pod: after fixing an apiserver config,
  `talosctl service kubelet restart` on each node.
- Hetzner boots the snapshot straight into an installed Talos; user data applies at first boot,
  a config sent to the maintenance API (port 50000, `--insecure`) on a blank server the same way.
- A second cluster restored from the same vault gets the same Discord webhook: silence its
  Alertmanager before syncing monitoring.
