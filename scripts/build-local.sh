#!/usr/bin/env bash
# Build + push a service image from this machine, for when GitHub Actions is unavailable.
# Usage: ./scripts/build-local.sh <unorouter|new-api|unorouter-bot> [--deploy]
#
# Produces the same artifact CI would: SHA tag only, never :latest (a floating tag never
# changes the manifest, so ArgoCD sees no diff and nothing deploys). --deploy also pins the
# tag in the app repo so ArgoCD rolls it out; without it the image is pushed and nothing else.
#
# Only unorouter bakes secrets into the image (Next.js inlines them at build time), so only
# it needs the .env dance below. GIT_SHA is passed to every repo but only unorouter declares
# the ARG; the others ignore it.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${1:?usage: build-local.sh <unorouter|new-api|unorouter-bot> [--deploy]}"
DEPLOY="${2:-}"
case "$REPO" in
  unorouter|new-api|unorouter-bot) ;;
  *) echo "unknown repo: $REPO (expected unorouter, new-api or unorouter-bot)" >&2; exit 1 ;;
esac
SRC="$(cd .. && pwd)/$REPO"
[ -d "$SRC" ] || { echo "no such repo: $SRC" >&2; exit 1; }
[ -f "$SRC/Dockerfile" ] || { echo "no Dockerfile in $SRC" >&2; exit 1; }
[ -f "$SRC/k8s/deployment.yaml" ] || { echo "no k8s/deployment.yaml in $SRC" >&2; exit 1; }

export KUBECONFIG="$PWD/kubeconfig"
# token via stdin, not argv: exec args land in the apiserver audit log + pod process table
BAO() { printf '%s\n' "$BT" | kubectl -n openbao exec -i openbao-0 -- sh -c "read -r BAO_TOKEN && export BAO_TOKEN && $*"; }
BT=$(sops -d secrets/openbao-init.sops.yaml | grep -oP 'root_token:\s*\K\S+')

echo ">> ghcr login"
BAO "bao kv get -format=json secret/ghcr-push" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["data"]["token"])' \
  | docker login ghcr.io -u 0-don --password-stdin

# unorouter bakes secrets at build time (Next.js inlines them); the others do not.
if [ "$REPO" = "unorouter" ]; then
  # The dev server reads this same .env, so a build must not leave the developer without
  # one. Stash any existing file and put it back on exit, however we exit.
  # backup lives OUTSIDE the repo: an in-repo .env.build-backup is not gitignored there,
  # so an interrupted build would leave secrets git-visible
  if [ -f "$SRC/.env" ]; then
    ENV_BK="$(mktemp -d)/env.backup"
    cp "$SRC/.env" "$ENV_BK"
    trap 'mv -f "$ENV_BK" "$SRC/.env" 2>/dev/null || true' EXIT
  else
    trap 'rm -f "$SRC/.env" 2>/dev/null || true' EXIT
  fi
  echo ">> materialize .env from OpenBao (gitignored; .env.public holds the public half)"
  cp "$SRC/.env.public" "$SRC/.env"
  BAO "bao kv get -format=json secret/unorouter-env" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]["data"]
# INTERNAL_API_URL is a ClusterIP; the SSG prerender fetches it at build time and this
# machine is not in the cluster. Same service, public route.
d["INTERNAL_API_URL"] = d.get("NEXT_PUBLIC_API_URL", "https://api.unorouter.com")
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

# .env is restored (or removed) by the EXIT trap set above.

if [ "$DEPLOY" = "--deploy" ]; then
  echo ">> pin $SHA in $REPO/k8s (ArgoCD deploys from there)"
  F="$SRC/k8s/deployment.yaml"
  sed -i "s|image: ghcr.io/unorouter/$REPO:.*|image: ghcr.io/unorouter/$REPO:$SHA|g" "$F"
  git -C "$SRC" add k8s/deployment.yaml
  git -C "$SRC" commit -m "deploy($REPO): $SHA

Built locally (GitHub Actions unavailable)."
  git -C "$SRC" push origin main
  # new-api pushes to a mirror (origin fetch and push URLs differ), so confirm the pin
  # actually reached the repo the ApplicationSet reads before claiming a deploy.
  # the contents API returns base64 wrapped at 60 chars, and `base64 -d` rejects the
  # embedded newlines, so without stripping them this check fails on a pin that IS live
  if ! gh api "/repos/unorouter/$REPO/contents/k8s/deployment.yaml" --jq .content 2>/dev/null \
       | tr -d '\n' | base64 -d | grep -q "$SHA"; then
    echo "!! pin is not visible on unorouter/$REPO -- ArgoCD reads that repo, so this did NOT deploy" >&2
    exit 1
  fi
  echo ">> pushed. ArgoCD picks it up within ~3min."
else
  echo ">> pushed to GHCR, NOT deployed. Re-run with --deploy to pin it."
fi
