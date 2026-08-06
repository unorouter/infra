#!/usr/bin/env bash
# Build + push a service image from this machine, for when GitHub Actions is unavailable.
# Usage: ./scripts/build-local.sh unorouter [--deploy]
#
# Produces the same artifact CI would: same GIT_SHA build arg, SHA tag only (never :latest,
# which never changes the manifest and so never deploys). --deploy also pins the tag in the
# app repo so ArgoCD rolls it out; without it the image is pushed but nothing deploys.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${1:?usage: build-local.sh <unorouter|new-api|unorouter-bot> [--deploy]}"
DEPLOY="${2:-}"
SRC="$(cd .. && pwd)/$REPO"
[ -d "$SRC" ] || { echo "no such repo: $SRC" >&2; exit 1; }

export KUBECONFIG="$PWD/kubeconfig"
BAO() { kubectl -n openbao exec openbao-0 -- sh -c "BAO_TOKEN=$BT $*"; }
BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')

echo ">> ghcr login"
BAO "bao kv get -format=json secret/ghcr-push" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["data"]["token"])' \
  | docker login ghcr.io -u 0-don --password-stdin

# unorouter bakes secrets at build time (Next.js inlines them); the others do not.
if [ "$REPO" = "unorouter" ]; then
  echo ">> materialize .env from OpenBao (gitignored; .env.public holds the public half)"
  cp "$SRC/.env.public" "$SRC/.env"
  BAO "bao kv get -format=json secret/unorouter-env" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]["data"]
# public vars already came from .env.public; only the real secrets are appended
print("\n".join(f"{k}={v}" for k, v in sorted(d.items()) if not k.startswith("NEXT_PUBLIC_")))
' >> "$SRC/.env"
fi

SHA=$(git -C "$SRC" rev-parse HEAD)
if [ -n "$(git -C "$SRC" status --porcelain | grep -v '^?? ')" ]; then
  echo "!! working tree dirty: the image would not match commit $SHA" >&2
  exit 1
fi

echo ">> build ghcr.io/unorouter/$REPO:$SHA (amd64)"
docker buildx build --platform linux/amd64 \
  --build-arg GIT_SHA="$SHA" \
  -t "ghcr.io/unorouter/$REPO:$SHA" \
  --push "$SRC"

[ "$REPO" = "unorouter" ] && rm -f "$SRC/.env"

if [ "$DEPLOY" = "--deploy" ]; then
  echo ">> pin $SHA in $REPO/k8s (ArgoCD deploys from there)"
  F="$SRC/k8s/deployment.yaml"
  sed -i "s|image: ghcr.io/unorouter/$REPO:.*|image: ghcr.io/unorouter/$REPO:$SHA|g" "$F"
  git -C "$SRC" add k8s/deployment.yaml
  git -C "$SRC" commit -m "deploy($REPO): $SHA

Built locally (GitHub Actions unavailable)."
  git -C "$SRC" push origin main
  echo ">> pushed. ArgoCD picks it up within ~3min."
else
  echo ">> pushed to GHCR, NOT deployed. Re-run with --deploy to pin it."
fi
