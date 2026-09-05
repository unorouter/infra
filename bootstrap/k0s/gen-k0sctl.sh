#!/usr/bin/env bash
# Renders bootstrap/k0s/k0sctl.yaml (gitignored) from k0sctl.tmpl.yaml plus the spares the
# sniper parked: Hetzner API for hostnames and private IPs, `tailscale status` for the SSH
# address. Usage: gen-k0sctl.sh [name-prefix]   (default unorouter-spare)
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ../../tofu/.env; set +a
PREFIX="${1:-unorouter-spare}"
python3 - "$PREFIX" <<'PY'
import json,os,subprocess,sys,urllib.request,yaml
prefix=sys.argv[1]
tok=os.environ["TF_VAR_hcloud_token"]
r=urllib.request.Request("https://api.hetzner.cloud/v1/servers?per_page=50",headers={"Authorization":"Bearer "+tok})
servers=[s for s in json.load(urllib.request.urlopen(r))["servers"] if s["name"].startswith(prefix+"-")]
if len(servers)<3: sys.exit(f"only {len(servers)} spares named {prefix}-*, need 3")
ts=json.loads(subprocess.check_output(["tailscale","status","--json"]))
tsip={p["HostName"]:p["TailscaleIPs"][0] for p in ts["Peer"].values()}
doc=yaml.safe_load(open("k0sctl.tmpl.yaml"))
hosts=[];sans=[]
for s in sorted(servers,key=lambda s:s["name"]):
    name=s["name"]; priv=s["private_net"][0]["ip"]
    if name not in tsip: sys.exit(f"{name} is not on the tailnet yet (cloud-init still running?)")
    hosts.append({"role":"controller+worker","noTaints":True,"hostname":name,"privateAddress":priv,
        "ssh":{"address":tsip[name],"user":"root","port":22},
        "installFlags":["--kubelet-extra-args=--fail-swap-on=false"],
        "files":[{"src":"../root-app.yaml","dstDir":"/var/lib/k0s/manifests/argocd-root","perm":"0644"}]})
    sans+=[tsip[name],name]
doc["spec"]["hosts"]=hosts
doc["spec"]["k0s"]["config"]["spec"]["api"]["sans"]=sans
yaml.safe_dump(doc,open("k0sctl.yaml","w"),sort_keys=False)
print("wrote k0sctl.yaml with",len(hosts),"hosts:",", ".join(h["hostname"] for h in hosts))
PY
