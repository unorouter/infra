#!/usr/bin/env bash
# Build + push a service image from this machine, for when GitHub Actions is unavailable.
# Usage: ./scripts/build-local.sh <unorouter|new-api|unorouter-bot|uno-import> [--deploy]
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

REPO="${1:?usage: build-local.sh <unorouter|new-api|unorouter-bot|uno-import> [--deploy]}"
DEPLOY="${2:-}"
case "$REPO" in
  unorouter|new-api|unorouter-bot|uno-import) ;;
  *) echo "unknown repo: $REPO (expected unorouter, new-api, unorouter-bot or uno-import)" >&2; exit 1 ;;
esac
ROOT="$(cd .. && pwd)"
SRC="$ROOT/$REPO"
[ -d "$SRC" ] || SRC="$ROOT/backup/$REPO"
[ -d "$SRC" ] || { echo "no such repo: $ROOT/$REPO" >&2; exit 1; }
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

# The image build sets ignoreBuildErrors, so a type error ships silently unless it is
# caught here. CI runs this as a separate job; locally it is the same gate, just inline.
# Lint is advisory (pre-existing react-hooks errors), matching CI's continue-on-error.
if [ -f "$SRC/package.json" ] && grep -q '"typecheck"' "$SRC/package.json"; then
  echo ">> typecheck"
  (cd "$SRC" && bun run typecheck) || { echo "!! typecheck failed, not building" >&2; exit 1; }
  if grep -q '"lint"' "$SRC/package.json"; then
    echo ">> lint (advisory)"
    (cd "$SRC" && bun run lint) || echo "!! lint reported problems (advisory, continuing)"
  fi
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

  # Everything below only makes sense once the new build is actually serving, and
  # only unorouter has a public site to check. new-api and the bot stop here.
  if [ "$REPO" = "unorouter" ]; then
    echo ">> waiting for $SHA to go live (ArgoCD polls git ~3min, then rollout + probes)"
    live=""
    for i in $(seq 1 240); do
      live=$(curl -fsS --max-time 10 "https://unorouter.com/api/ops/health?hc=$i-$RANDOM" 2>/dev/null \
             | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
      [ "$live" = "$SHA" ] && break
      printf '\r   live=%.12s want=%.12s  %d/240' "$live" "$SHA" "$i"
      sleep 10
    done
    echo
    if [ "$live" != "$SHA" ]; then
      echo "!! never went live; skipping post-deploy steps (check ArgoCD sync)" >&2
      exit 1
    fi
    echo ">> live"

    # Guards the localhost-self-call regression that silently emptied every model
    # page from the sitemap. Fails loudly rather than leaving SEO quietly broken.
    echo ">> assert sitemap has model pages"
    sm=$(curl -fsS --max-time 60 "https://unorouter.com/sitemap.xml")
    models=$(printf '%s' "$sm" | grep -oE '<loc>[^<]*</loc>' \
      | grep -cE '/(models|modeles|modelle|moxing|mo-hinh|moderu|modelli|modelos|modeu|modeller|model|modele|madal)/[^<]+' || true)
    echo "   $(printf '%s' "$sm" | grep -c '<loc>') urls, $models model pages"
    [ "${models:-0}" -ge 100 ] || { echo "!! only $models model pages (expected >=100); pricing self-call likely failing" >&2; exit 1; }

    # Read once: both the purge and IndexNow need these.
    eval "$(BAO "bao kv get -format=json secret/unorouter-env" | python3 -c '
import sys, json, shlex
d = json.load(sys.stdin)["data"]["data"]
for k in ("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ZONE_ID", "INDEXNOW_KEY"):
    if d.get(k):
        print(f"export {k}={shlex.quote(d[k])}")
')"

    # Locale roots ONLY, never purge_everything: that evicts content-hashed
    # /_next/static chunks, and every already-open tab and installed PWA then dies
    # with ChunkLoadError. Chunk names are immutable so stale entries are harmless.
    echo ">> purge Cloudflare (locale roots only)"
    urls=$(printf '"https://unorouter.com/%s",' en de fr it es pt-BR ja ko ru tr ar he hi id pl vi zh-CN zh-TW)
    curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/purge_cache" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
      --data "{\"files\":[${urls}\"https://unorouter.com/\"]}" >/dev/null \
      && echo "   purged" || echo "!! purge failed (non-fatal)"

    echo ">> IndexNow"
    (cd "$SRC" && NEXT_PUBLIC_URL=https://unorouter.com INDEXNOW_KEY="$INDEXNOW_KEY" \
      bun add indexnow-submitter --no-save >/dev/null 2>&1 && bun scripts/indexnow.ts) \
      || echo "!! IndexNow failed (non-fatal)"

    # Only the default locale prerenders at build, so walk the shallow URLs to make
    # the other 17 ISR-render warm instead of on a visitor's first hit. Depth <=5
    # keeps this to the locale roots + section pages, not the ~22k model URLs.
    echo ">> warm ISR cache"
    printf '%s' "$sm" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g' \
      | awk -F/ 'NF<=5' > /tmp/warm-urls.txt
    echo "   warming $(wc -l < /tmp/warm-urls.txt) urls"
    timeout 12m xargs -P 12 -n 1 -a /tmp/warm-urls.txt -I{} \
      curl -s -o /dev/null -w '%{http_code} {}\n' --max-time 15 {} > /tmp/warm-codes.txt 2>/dev/null || true
    cut -d' ' -f1 /tmp/warm-codes.txt | sort | uniq -c
    grep -v '^200 ' /tmp/warm-codes.txt | head -20 || true
  fi
else
  echo ">> pushed to GHCR, NOT deployed. Re-run with --deploy to pin it."
fi
