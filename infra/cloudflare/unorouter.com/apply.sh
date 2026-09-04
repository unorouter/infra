#!/usr/bin/env bash
# Applies the edge rulesets for zone unorouter.com. Two pre-built modes:
#   apply.sh            -> rules.sops.yaml         (normal)
#   apply.sh attack     -> rules.attack.sops.yaml  (the pre-built attack rule set)
# CF_PLAN=free reshapes for the free plan: no SBFM skip, one 10 s rate limit, no managed WAF.
#   apply.sh normal     -> back to normal
# Optional phase names after the mode apply only those phases. PUT replaces a phase, so this is idempotent.
# Auth: CF_API_TOKEN (Bearer, zone-scoped) or, until it exists, CF_EMAIL + CF_API_KEY.
set -euo pipefail
ZONE=bc178db579d52011b4b2998da622b9e3
cd "$(dirname "$0")"
MODE=normal; case "${1:-}" in attack|normal) MODE=$1; shift;; esac
FILE=rules.sops.yaml; [ "$MODE" = attack ] && FILE=rules.attack.sops.yaml
if [ -n "${CF_API_TOKEN:-}" ]; then AUTH=(-H "Authorization: Bearer $CF_API_TOKEN"); else AUTH=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_API_KEY"); fi
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
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sys.argv[1], "ok" if d["success"] else d["errors"])' "$phase"
done
