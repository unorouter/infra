#!/usr/bin/env python3
"""Fail when a change moves any alert to different Alertmanager receivers.

Routes every alert rule (Prometheus and Loki rule files, plus the alerts pollers raise through
watch-lib) through the routes in alerting/alertmanager-config.yaml and compares the receivers
with scripts/alert-routing.snapshot.json. A deliberate change is accepted with --update, which
rewrites the snapshot so the diff shows up in the commit.
"""
import glob
import json
import re
import sys

import yaml

SNAPSHOT = "scripts/alert-routing.snapshot.json"
CONFIG = "infra/monitoring/extras/alerting/alertmanager-config.yaml"
# Raised by pollers through watch-lib, which adds page: "true" to every critical.
POLLER_ALERTS = {
    "cloudflare-audit-watch": ["CloudflareAccessForeignLogin"],
    "ghcr-visibility-watch": ["PublicPackageExposed"],
    "github-watch": ["GitHubDeployKey", "GitHubRepoCreated", "GitHubRulesetInactive", "GitHubUnexpectedApp",
                     "GitHubUnexpectedCommit", "GitHubUnexpectedMember", "GitHubWebhook"],
    "hetzner-watch": ["HetznerProjectAction"],
    "image-secret-scan": ["ImageSecretLeak"],
    "tailscale-watch": ["TailscaleUnknownDevice", "TailscaleDeviceAdded", "TailscaleKeyCreated", "TailscaleTailnetChanged"],
}
POLLER_WARNINGS = {"edge-probe-watch": ["EdgeProbeSweep", "TeleportSignin"]}


def rules():
    found = []

    def walk(o):
        if isinstance(o, dict):
            if "alert" in o:
                found.append((o["alert"], {k: str(v) for k, v in (o.get("labels") or {}).items()}))
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
        elif isinstance(o, str) and "alert:" in o and "groups" in o:
            try:
                walk(yaml.safe_load(o))
            except yaml.YAMLError:
                pass

    for f in sorted(glob.glob("infra/**/*.yaml", recursive=True)):
        try:
            for d in yaml.safe_load_all(open(f)):
                walk(d)
        except yaml.YAMLError:
            pass
    for src, names in POLLER_ALERTS.items():
        found += [(n, {"severity": "critical", "source": src, "page": "true"}) for n in names]
    for src, names in POLLER_WARNINGS.items():
        found += [(n, {"severity": "warning", "source": src}) for n in names]
    return found


def matches(route, labels):
    for m in route.get("matchers", []):
        v, want, op = labels.get(m["name"], ""), m["value"], m.get("matchType", "=")
        ok = {"=": v == want, "!=": v != want,
              "=~": re.fullmatch(want, v) is not None, "!~": re.fullmatch(want, v) is None}[op]
        if not ok:
            return False
    return True


def receivers(labels, routes):
    got = []
    for r in routes:
        if matches(r, labels):
            got.append(r["receiver"])
            if not r.get("continue"):
                break
    return got


def main():
    cfg = next(d for d in yaml.safe_load_all(open(CONFIG)) if d and d.get("kind") == "AlertmanagerConfig")
    routes = cfg["spec"]["route"]["routes"]
    now = {}
    for name, labels in rules():
        labels = dict(labels, alertname=name)
        key = "|".join([name, labels.get("severity", ""), labels.get("source", ""),
                        "page" if labels.get("page") == "true" else "", labels.get("burn_in", "")])
        now[key] = receivers(labels, routes)
    if "--update" in sys.argv:
        json.dump(now, open(SNAPSHOT, "w"), indent=1, sort_keys=True)
        print(f"alert routing: snapshot updated ({len(now)} alert variants)")
        return 0
    try:
        before = json.load(open(SNAPSHOT))
    except FileNotFoundError:
        print(f"alert routing: no {SNAPSHOT}, run with --update", file=sys.stderr)
        return 1
    diff = [(k, before.get(k), now.get(k)) for k in sorted(set(before) | set(now)) if before.get(k) != now.get(k)]
    for k, a, b in diff:
        print(f"alert routing changed: {k}\n    was {a}\n    now {b}", file=sys.stderr)
    if diff:
        print("alert routing: if intended, run scripts/check-alert-routing.py --update and commit the snapshot",
              file=sys.stderr)
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
