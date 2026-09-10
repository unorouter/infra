#!/usr/bin/env bash
# Build the Hetzner snapshot for one Talos version from the Image Factory schematic. Run once
# per Talos version; prints the snapshot id. Boots a temporary rescue server, dd's the image,
# snapshots it, deletes the server. Needs one free server slot in the project.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?talos version, e.g. v1.13.10}"
export PATH="$HOME/.local/bin:$PATH"
set -a; . ../../tofu/.env; set +a
export HCLOUD_TOKEN="$TF_VAR_hcloud_token"
ID=$(curl -sf -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "schematic $ID"
hcloud-upload-image upload \
  --image-url "https://factory.talos.dev/image/$ID/$VERSION/hcloud-amd64.raw.xz" \
  --architecture x86 --compression xz --location nbg1 \
  --description "Talos $VERSION $ID" \
  --labels "os=talos,talos=$VERSION,schematic=${ID:0:12}"
curl -sf -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=talos=$VERSION" \
  | python3 -c 'import sys,json;[print("snapshot", i["id"], i["description"]) for i in json.load(sys.stdin)["images"]]'
