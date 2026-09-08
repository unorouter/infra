# Cloudflare edge

`infra/cloudflare/unorouter.com/`: `rules.sops.yaml` (normal), `rules.attack.sops.yaml` (attack),
one key per ruleset phase, encrypted because the rule text is the attacker's playbook.
`apply.sh [normal|attack] [phase...]` PUTs each phase with a zone-scoped `CF_API_TOKEN` and
fetches the daily sops key from OpenBao itself. Intent: machine surface (relay paths, PAT calls,
preflights, webhooks, MCP) skips bot management; browser surfaces are challenged on signal; a
per-IP auto-ban catches single-source floods. Details: `incidents/2026-09-03-l7-ddos.md`.

- A challenge only renders on a page navigation. A fetch, service worker, manifest or OAuth start
  cannot, so those paths are skipped or blocked, never challenged (9,345 silent failures in one
  day before this rule).
- Pro until 2027-09. Downgrade day: `CF_PLAN=free ./apply.sh`.
- **After every rule change**: allowlist checks from the incident report, then `./mitigations.py
  <hours>`. A webhook sender, CLI client or OPTIONS preflight in that list is a false positive.
- Header-name checks must use `lower(http.request.headers.names[*])`.
- 504s with origin status 0 and UA "…early hints" are Cloudflare synthetics, filter them out
  before reading any 5xx rate.
