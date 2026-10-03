#!/usr/bin/env python3
"""Who did the edge mitigate? Prints every non-skip firewall event of the last N hours
grouped by rule, host, path, method, user agent and ASN, so real clients caught by a rule
stand out (webhooks, CLI tools, preflights). Usage:
  CF_API_TOKEN=... CF_ZONE_ID=... ./mitigations.py [hours=3]"""
import collections, datetime, json, os, sys, urllib.request

hours = float(sys.argv[1]) if len(sys.argv) > 1 else 3
end = datetime.datetime.now(datetime.UTC).replace(microsecond=0)
start = end - datetime.timedelta(hours=hours)
q = """query($z:String,$s:String,$e:String){viewer{zones(filter:{zoneTag:$z}){
 firewallEventsAdaptive(filter:{datetime_geq:$s,datetime_leq:$e,action_neq:"skip"},limit:10000,orderBy:[datetime_DESC]){
  datetime action source description clientRequestHTTPHost clientRequestPath clientRequestHTTPMethodName
  userAgent clientIP clientASNDescription clientCountryName}}}}"""
body = json.dumps({"query": q, "variables": {"z": os.environ["CF_ZONE_ID"],
        "s": start.isoformat().replace("+00:00", "Z"), "e": end.isoformat().replace("+00:00", "Z")}}).encode()
req = urllib.request.Request("https://api.cloudflare.com/client/v4/graphql", data=body,
        headers={"Authorization": "Bearer " + os.environ["CF_API_TOKEN"], "Content-Type": "application/json"})
ev = json.load(urllib.request.urlopen(req))["data"]["viewer"]["zones"][0]["firewallEventsAdaptive"]
ev = [e for e in ev if e["action"] != "allow"]
print(f"{len(ev)} mitigated events {start:%H:%M}..{end:%H:%M} UTC (10000 = window truncated)\n")
rule = lambda e: (e["description"] or e["source"])[:40]
by_rule = collections.Counter((e["action"], rule(e)) for e in ev)
for k, v in by_rule.most_common():
    print(f"{v:6d}  {k[0]:<28} {k[1]}")
print("\nby rule / host / method / path / user agent / ASN (top 60)")
detail = collections.Counter((e["action"][:12], rule(e)[:24], e["clientRequestHTTPHost"], e["clientRequestHTTPMethodName"],
        e["clientRequestPath"][:44], (e["userAgent"] or "")[:36], e["clientASNDescription"][:18], e["clientCountryName"]) for e in ev)
for k, v in detail.most_common(60):
    print(f"{v:5d}  " + " | ".join(k))
ips = collections.defaultdict(set)
for e in ev:
    ips[rule(e)].add(e["clientIP"])
print("\ndistinct IPs per rule")
for k, v in sorted(ips.items(), key=lambda x: -len(x[1])):
    print(f"{len(v):5d}  {k}")
