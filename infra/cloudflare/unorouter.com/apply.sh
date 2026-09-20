#!/usr/bin/env bash
# Applies the edge rulesets for zone unorouter.com. Two pre-built modes:
#   apply.sh            -> rules.sops.yaml         (normal)
#   apply.sh attack     -> rules.attack.sops.yaml  (the pre-built attack rule set)
# CF_PLAN=free reshapes for the free plan: no SBFM skip, one 10 s rate limit, no managed WAF.
#   apply.sh normal     -> back to normal
# Optional phase names after the mode apply only those phases. PUT replaces a phase, so this is idempotent.
# Auth: CF_API_TOKEN (Bearer, zone-scoped). When unset it is read from OpenBao secret/cloudflare-edge
# field token, the same way the sops key is. CF_EMAIL + CF_API_KEY only when both are exported.
set -euo pipefail
ZONE=bc178db579d52011b4b2998da622b9e3
cd "$(dirname "$0")"
MODE=normal; case "${1:-}" in attack|normal) MODE=$1; shift;; esac
FILE=rules.sops.yaml; [ "$MODE" = attack ] && FILE=rules.attack.sops.yaml
# daily sops key from OpenBao (Teleport app proxy + OIDC token), never a file on disk
export PATH="$HOME/.local/bin:$PATH"   # bao, tsh, tctl live there
[ -n "${SOPS_AGE_KEY:-}" ] || export SOPS_AGE_KEY=$(BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}" bao kv get -field=key secret/sops-age)
if [ -z "${CF_API_TOKEN:-}" ] && [ -z "${CF_API_KEY:-}" ]; then
  CF_API_TOKEN=$(BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}" bao kv get -field=token secret/cloudflare-edge) || true
fi
if [ -n "${CF_API_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer $CF_API_TOKEN")
elif [ -n "${CF_EMAIL:-}" ] && [ -n "${CF_API_KEY:-}" ]; then AUTH=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_API_KEY")
else echo "no Cloudflare credential: export CF_API_TOKEN or log in to OpenBao (scripts/bao.sh login)" >&2; exit 1; fi
echo "mode: $MODE ($FILE)"
sops -d "$FILE" | python3 -c '
import sys,os,yaml,json
d=yaml.safe_load(sys.stdin); want=sys.argv[1:] or list(d)
if os.environ.get("CF_PLAN")=="free":
    for r in d["http_request_firewall_custom"]: r.get("action_parameters",{}).pop("phases",None)
    d["http_ratelimit"]=d["http_ratelimit"][:1]; d["http_ratelimit"][0]["ratelimit"].update(period=10,requests_per_period=200,mitigation_timeout=10)
    d.pop("http_request_firewall_managed",None)
for phase in want: print(json.dumps({"phase":phase,"rules":d[phase]}))
' "$@" | while read -r line; do
  phase=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin)["phase"])')
  printf '%s' "$line" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps({"rules":d["rules"]}))' \
  | curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/$phase/entrypoint" "${AUTH[@]}" -H 'Content-Type: application/json' --data @- \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sys.argv[1], "ok" if d["success"] else d["errors"]); sys.exit(0 if d["success"] else 1)' "$phase"
  # Read back what is live: an edited file that never reached the edge must not look applied.
  live=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE/rulesets/phases/$phase/entrypoint" "${AUTH[@]}"     | python3 -c 'import sys,json; r=json.load(sys.stdin).get("result") or {}; print(len(r.get("rules",[])))')
  want=$(printf '%s' "$line" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["rules"]))')
  [ "$live" = "$want" ] && echo "$phase live: $live rules" || { echo "$phase live has $live rules, file has $want" >&2; exit 1; }
done
