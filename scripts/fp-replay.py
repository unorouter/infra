#!/usr/bin/env python3
"""Offline replay of the fp-autoban scorer (infra/monitoring/extras/alerting/fp-autoban.yaml).

  fp-replay.py loki START END OUT.jsonl.gz     pull [fp] and gateway fp lines once (LOKI_ADDR)
  fp-replay.py list runs|waves [YYYY/MM/DD]    list the archive (OpenBao session for the keys)
  fp-replay.py fetch runs DAY [LAST_DAY] DIR   download archived runs, DAY as YYYY-MM-DD
  fp-replay.py fetch wave ID DIR               download one wave folder (ID from list waves)
  fp-replay.py score [--set FP_X=V]... [--sweep FP_X=a,b,c] [--state STATE.json] FILE...

score reads lines files (Loki pulls, wave lines*.jsonl.gz) or runs files (runs/**/*.jsonl.gz),
walks them minute by minute with the controller's own code and window, and prints the first
minute each candidate appears. Nothing here talks to Cloudflare or the cluster.
"""
import argparse, datetime, glob, gzip, importlib.util, json, os, subprocess, sys, tempfile, types, urllib.parse, urllib.request
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "infra/monitoring/extras/alerting/fp-autoban.yaml")
BUCKET = "unorouter-sync"
PREFIX = "fp-autoban"


def load_autoban(env):
    import yaml
    docs = [d for d in yaml.safe_load_all(open(MANIFEST)) if d]
    src = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "fp-autoban")["data"]["autoban.py"]
    path = os.path.join(tempfile.mkdtemp(prefix="fp-replay-"), "autoban.py")
    open(path, "w").write(src)
    sys.modules["notify"] = types.SimpleNamespace(alert=lambda *a, **k: None, digest=lambda *a, **k: None)
    keep = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location(f"autoban_{len(sys.modules)}", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        for k, v in keep.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
    mod.ARCHIVE = ""
    return mod


def records(files):
    for f in files:
        with gzip.open(f, "rt") if f.endswith(".gz") else open(f) as fh:
            for line in fh:
                if line.strip(): yield json.loads(line)


def minutes_from_lines(ab, recs):
    by = defaultdict(list)
    for r in recs:
        by[(r["ts"] // 60_000_000_000 + 1) * 60].append((r["ts"], r["src"], r["line"]))
    if not by: return []
    first, last = min(by), max(by)
    return [ab.minute_from_lines(t, sorted(by.get(t, []))) for t in range(first, last + 60, 60)]


def minutes_from_runs(ab, recs):
    seen, out = set(), []
    for r in recs:
        for m in r.get("minutes", []):
            if m["t"] in seen: continue
            seen.add(m["t"])
            groups, authed = defaultdict(ab.Agg), defaultdict(set)
            for x in m["groups"]:
                g = groups[(x["c"], x["l"], x["e"], x["h"], x["fam"])]
                g.n, g.authed, g.lines, g.bl = x["n"], x["authed"], x["lines"], x["bl"]
                g.ips = Counter(x["ips"])
                # past 500 addresses only the count was kept
                for i in range(x["nips"] - len(x["ips"])): g.ips[f"x:{m['t']}:{i}"] = 1
                g.asn, g.src, g.ua, g.paths, g.minutes = Counter(x["asn"]), Counter(x["src"]), Counter(x["ua"]), set(x["paths"]), {m["t"]}
                if g.authed: authed[ab.fpkey(x["c"], x["l"], x["e"])] |= set(x["ips"])
            out.append({"t": m["t"], "groups": groups, "authed": authed, "truncated": m["truncated"],
                        "parsed": m["parsed"], "skipped": m["unparsed"], "raw": []})
    return sorted(out, key=lambda m: m["t"])


def load_minutes(ab, files):
    recs = list(records(files))
    if not recs: return [], None
    if "line" in recs[0]: return minutes_from_lines(ab, recs), None
    return minutes_from_runs(ab, recs), recs[0].get("baseline")


def state_from(ab, path, minutes, run_baseline):
    st = {"baseline": {"since": minutes[0]["t"] if minutes else 0, "k": {}}, "posted": {}, "post_times": [], "adds": [], "kill": "0"}
    if path:
        data = json.load(open(path))
        st["baseline"] = json.loads(data["baseline"]) if isinstance(data.get("baseline"), str) else data["baseline"]
    elif run_baseline:
        st["baseline"]["since"] = minutes[0]["t"] - run_baseline["age_days"] * 86400
    return st


def hhmm(t): return datetime.datetime.fromtimestamp(t - 60, datetime.UTC).strftime("%Y-%m-%d %H:%M")


def replay(ab, minutes, st, learn, quiet=False):
    window, first = [], {}
    for m in minutes:
        ab.clock = lambda t=m["t"]: t
        if learn: ab.learn_baseline(st, m)
        window = (window + [m])[-ab.WINDOW:]
        _, cands = ab.score(window, st)
        for x in cands:
            if x["id"] in first: continue
            first[x["id"]] = (m["t"], x)
            if quiet: continue
            print(f"{hhmm(m['t'])}  {'EXCLUDED ' + x['excluded'] if x['excluded'] else 'CANDIDATE'}")
            print("  " + ab.evidence(x, st).replace("\n", "\n  ") + "\n")
    return first


def cmd_score(a):
    env = dict(kv.split("=", 1) for kv in a.set)
    if a.sweep:
        key, values = a.sweep.split("=", 1)
        print(f"{key:>24}  candidates (not excluded), first minute each")
        for v in values.split(","):
            ab = load_autoban({**env, key: v})
            minutes, rb = load_minutes(ab, a.files)
            first = replay(ab, minutes, state_from(ab, a.state, minutes, rb), learn=not rb, quiet=True)
            hits = [f"{x['id']}@{hhmm(t)[11:]}:{x['tier']}:{x['g'].n}r/{len(x['g'].ips)}ip" for t, x in first.values() if not x["excluded"]]
            excl = sum(1 for _, x in first.values() if x["excluded"])
            print(f"{v:>24}  {len(hits)} {' '.join(hits)}  (excluded {excl})")
        return
    ab = load_autoban(env)
    minutes, rb = load_minutes(ab, a.files)
    if not minutes: sys.exit("no records")
    st = state_from(ab, a.state, minutes, rb)
    print(f"{len(minutes)} minutes {hhmm(minutes[0]['t'])} to {hhmm(minutes[-1]['t'])} UTC, "
          f"{sum(g.n for m in minutes for g in m['groups'].values())} requests, "
          f"baseline {len(st['baseline']['k'])} keys, "
          f"thresholds {json.dumps(ab.THRESHOLDS)}\n")
    first = replay(ab, minutes, st, learn=not rb)
    live = [x for _, x in first.values() if not x["excluded"]]
    print(f"{len(live)} candidate(s), {len(first) - len(live)} excluded")


def cmd_loki(a):
    base = os.environ.get("LOKI_ADDR", "http://127.0.0.1:18300/api/datasources/proxy/uid/loki")
    queries = {"site": r'{namespace="services",app="unorouter"} |= `[fp] `',
               "api": '{namespace="services",app="new-api"} |= " | fp "'}
    ns = lambda s: int(datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.UTC).timestamp()) * 10**9
    start, end, n = ns(a.start), ns(a.end), 0
    with gzip.open(a.out, "wt") as f:
        for src, q in queries.items():
            cur = start
            while True:
                u = base + "/loki/api/v1/query_range?" + urllib.parse.urlencode(
                    {"query": q, "start": cur, "end": end, "limit": 5000, "direction": "forward"})
                d = json.load(urllib.request.urlopen(u, timeout=120))
                got = sorted((int(ts), line) for s in d["data"]["result"] for ts, line in s["values"])
                for ts, line in got: f.write(json.dumps({"ts": ts, "src": src, "line": line}) + "\n")
                n += len(got)
                if len(got) < 5000: break
                cur = got[-1][0] + 1
    print(f"{a.out}: {n} lines")


def rclone_env():
    def kv(path):
        return json.loads(subprocess.run(["bao", "kv", "get", "-format=json", path], check=True,
                                         capture_output=True, text=True).stdout)["data"]["data"]
    def obscure(v):
        return subprocess.run(["rclone", "obscure", "-"], input=v, check=True, capture_output=True, text=True).stdout.strip()
    hz, enc = kv("secret/pg-s3"), kv("secret/backup-encryption")
    return {**os.environ,
            "RCLONE_CONFIG_HZ_TYPE": "s3", "RCLONE_CONFIG_HZ_PROVIDER": "Ceph", "RCLONE_CONFIG_HZ_REGION": "fsn1",
            "RCLONE_CONFIG_HZ_ENDPOINT": "https://fsn1.your-objectstorage.com", "RCLONE_CONFIG_HZ_NO_CHECK_BUCKET": "true",
            "RCLONE_CONFIG_HZ_ACCESS_KEY_ID": hz["ACCESS_KEY_ID"], "RCLONE_CONFIG_HZ_SECRET_ACCESS_KEY": hz["ACCESS_SECRET_KEY"],
            "RCLONE_CONFIG_CR_TYPE": "crypt", "RCLONE_CONFIG_CR_REMOTE": "hz:", "RCLONE_CONFIG_CR_FILENAME_ENCRYPTION": "off",
            "RCLONE_CONFIG_CR_DIRECTORY_NAME_ENCRYPTION": "false", "RCLONE_CONFIG_CR_SUFFIX": "none",
            "RCLONE_CONFIG_CR_PASSWORD": obscure(enc["crypt_password"]), "RCLONE_CONFIG_CR_PASSWORD2": obscure(enc["crypt_salt"])}


def cmd_list(a):
    path = f"cr:{BUCKET}/{PREFIX}/{a.kind}/" + (a.day or "")
    flag = ["--dirs-only"] if a.kind == "waves" and not a.day else ["-R"]
    subprocess.run(["rclone", "lsf", *flag, path], env=rclone_env(), check=True)


def cmd_fetch(a):
    env = rclone_env()
    if a.kind == "wave":
        src = f"{PREFIX}/waves/{a.args[0]}"
        subprocess.run(["rclone", "copy", f"cr:{BUCKET}/{src}", os.path.join(a.args[1], src)], env=env, check=True)
        return
    day = datetime.date.fromisoformat(a.args[0])
    last = datetime.date.fromisoformat(a.args[1]) if len(a.args) == 3 else day
    while day <= last:
        src = f"{PREFIX}/runs/{day:%Y/%m/%d}"
        subprocess.run(["rclone", "copy", f"cr:{BUCKET}/{src}", os.path.join(a.args[-1], src)], env=env, check=True)
        day += datetime.timedelta(days=1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("score")
    s.add_argument("--set", action="append", default=[], help="FP_ENV=value, as in the Deployment")
    s.add_argument("--sweep", help="FP_ENV=a,b,c: one replay per value, candidates only")
    s.add_argument("--state", help="fp-autoban-state ConfigMap data as JSON, for the logged in baseline")
    s.add_argument("files", nargs="+")
    l = sub.add_parser("loki"); l.add_argument("start"); l.add_argument("end"); l.add_argument("out")
    ls = sub.add_parser("list"); ls.add_argument("kind", choices=["runs", "waves"]); ls.add_argument("day", nargs="?")
    f = sub.add_parser("fetch"); f.add_argument("kind", choices=["runs", "wave"]); f.add_argument("args", nargs="+")
    a = p.parse_args()
    if a.cmd == "score":
        pats = [os.path.join(x, "**/*.jsonl.gz") if os.path.isdir(x) else x for x in a.files]
        # a wave's run.json.gz is the record that opened it, not lines
        a.files = sorted(x for pat in pats for x in (glob.glob(pat, recursive=True) or [pat])
                         if os.path.isfile(x) and not x.endswith("run.json.gz")) or sys.exit("no files")
    {"score": cmd_score, "loki": cmd_loki, "list": cmd_list, "fetch": cmd_fetch}[a.cmd](a)


if __name__ == "__main__":
    main()
