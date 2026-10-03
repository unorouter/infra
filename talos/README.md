# Talos nodes

A node is the Image Factory snapshot plus one rendered machine config. No shell, no SSH, no
package manager; `talosctl` over the tailnet is the whole management path.

| File | |
| --- | --- |
| `schematic.yaml` | Image Factory schematic (`tailscale` only), id `4a0d65c6...`, on every node since the 1.14.1 upgrade |
| `talconfig.yaml`, `patches/` | talhelper input; every non-obvious setting is commented where it is set |
| `patches/firewall.yaml` | node firewall, default block; every host port and its clients are listed there |
| `talsecret.sops.yaml` | cluster secrets (`talhelper gensecret`), break-glass key only; `secretboxencryptionsecret` stays empty, the key lives in `patches/etcd-encryption.yaml` |
| `talenv.sops.yaml` | `${...}` substitutions: per node `WG_NODE1x_{PRIVATE,PUBLIC,ENDPOINT}`, `TS_AUTHKEY`, `SECRETBOX_KEY3` |

`clusterconfig/` (rendered configs, talosconfig) is gitignored, never committed.

## Render

```sh
cd talos && SOPS_AGE_KEY_FILE=/run/media/veracrypt1/unorouter/sops-age-keys.txt talhelper genconfig
wc -c clusterconfig/*.yaml      # Hetzner caps user data at 32768 bytes
```

Apply: `talosctl -n <node> apply-config -f clusterconfig/unorouter-<node>.yaml` (most settings
live, the output says when a reboot is needed). Never `talosctl edit mc`: the next render undoes
it. Rotation order and traps for every key here: `docs/operations.md`, "Rotating cluster secrets".

`TS_AUTHKEY` in `talenv.sops.yaml` is revoked. Running nodes keep their tailnet identity in
`EPHEMERAL` and never need it again. A new node, or one whose `EPHEMERAL` was wiped, gets a fresh
key right before its render: single use, tagged `tag:node`, pre-signed for Tailnet Lock
(`tailscale lock sign`), shortest expiry, revoked once the node has joined: a reusable key in a
rendered config is a standing tailnet join for whoever gets hold of that render.

## Image, once per Talos version

```sh
ID=$(curl -sf -X POST --data-binary @talos/schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
HCLOUD_TOKEN=... hcloud-upload-image upload \
  --image-url "https://factory.talos.dev/image/$ID/v1.14.1/hcloud-amd64.raw.xz" \
  --architecture x86 --compression xz --location nbg1 \
  --description "Talos v1.14.1 $ID" --labels "os=talos,talos=v1.14.1,schematic=${ID:0:12}"
```

Current snapshot: v1.14.1, schematic `4a0d65c6` (2026-09-30); tofu picks the newest `os=talos`
snapshot. A 1.14 node names its NIC `enp1s0`, which the `deviceSelector` in `talconfig.yaml`
covers. A server's `user_data` only changes with a rebuild: the three nodes still carry
configs whose keys were all rotated, and a rebuild would put live keys there instead.

## A new node

Created with its rendered config as user data, nothing else.
`STATE` is encrypted from the first boot (the `VolumeConfig STATE` document in
`patches/volumes.yaml`).

A rendered config is the whole cluster (every CA key, the service account key, the tailnet
key), so it is rendered on the operator laptop, sent to Hetzner and shredded, never copied to
another host. Existing nodes learn about a new one only once it has a public address: a peer
entry without an endpoint accepts a handshake from anywhere, and whoever holds the new node's
config holds its private key.

1. `openssl genpkey -algorithm X25519` key pair into `talenv.sops.yaml` (`WG_NODE14_PRIVATE`,
   `WG_NODE14_PUBLIC`).
2. `talconfig.yaml`: the node14 row only (`ipAddress: unorouter-node14.taild195fa.ts.net`,
   `10.200.0.14/24`, peers with the existing endpoints, its SAN). No node14 peer in the
   existing rows yet.
3. From the laptop: the entry in `local.nodes` (`tofu/nodes.tf`), render, `tofu apply`, shred
   the render. Sold out: wait for stock from the laptop; a stock watcher only notifies.
4. With the server's public address known: `WG_NODE14_ENDPOINT` in `talenv.sops.yaml`, a node14
   peer with that endpoint in every existing row and the address in the `wireguard` rule of
   `patches/firewall.yaml`. Render, `apply-config` on each existing node (live), shred.
5. Three minutes later `talosctl -n unorouter-node14.taild195fa.ts.net health` passes; the
   Hetzner rule follows `local.nodes`.

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

- Any explicit link in the machine config switches off Talos's default DHCP, so the physical
  NIC is listed with `dhcp: true` on purpose next to `wg0`, by `deviceSelector: {physical: true}`
  and never by name: Talos 1.14 renamed `eth0` to `enp1s0`, and a config naming `eth0` left
  node12 without an address after its upgrade (2026-09-29).
- The kubelet does not retry a rejected static pod: after fixing an apiserver config,
  `talosctl service kubelet restart` on each node.
- Hetzner boots the snapshot straight into an installed Talos; user data applies at first boot,
  a config sent to the maintenance API (port 50000, `--insecure`) on a blank server the same way.
- A second cluster restored from the same vault gets the same Discord webhook: silence its
  Alertmanager before syncing monitoring.
