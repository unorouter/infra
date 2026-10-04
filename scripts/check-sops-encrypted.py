#!/usr/bin/env python3
"""Refuse a commit that stages a plaintext secret in this public repo.

Checks the STAGED content (git index) of every *.sops.yaml: it must carry sops metadata, and
every value the matching .sops.yaml creation rule encrypts must be an ENC[...] string. A file
under secrets/ that is not a *.sops.yaml is refused outright. Usage: check-sops-encrypted.py
[path ...] (default: all staged files).
"""
import os
import re
import subprocess
import sys

import yaml


def staged_paths():
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                         capture_output=True, text=True, check=True).stdout
    return [p for p in out.splitlines() if p]


def staged_text(path):
    return subprocess.run(["git", "show", f":{path}"], capture_output=True, text=True, check=True).stdout


def creation_rule(path, rules):
    for r in rules:
        if re.search(r.get("path_regex", ""), path):
            return r
    return None


def plaintext_leaves(node, enc_re, inside, trail=""):
    if isinstance(node, dict):
        for k, v in node.items():
            if trail == "" and k == "sops":
                continue
            yield from plaintext_leaves(v, enc_re, inside or (enc_re is not None and re.search(enc_re, str(k))), f"{trail}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from plaintext_leaves(v, enc_re, inside, f"{trail}[{i}]")
    elif (enc_re is None or inside) and node not in (None, "") and not str(node).startswith("ENC["):
        yield trail or "."


def main(argv):
    rules = yaml.safe_load(open(".sops.yaml")).get("creation_rules", [])
    paths = argv or staged_paths()
    bad = []
    for p in paths:
        if p.startswith("secrets/") and not p.endswith(".sops.yaml"):
            bad.append(f"{p}: files under secrets/ must be *.sops.yaml")
            continue
        if not p.endswith(".sops.yaml") or os.path.basename(p) == ".sops.yaml":
            continue
        try:
            docs = [d for d in yaml.safe_load_all(staged_text(p) if not argv else open(p).read()) if d is not None]
        except Exception as e:
            bad.append(f"{p}: not valid YAML ({e})")
            continue
        rule = creation_rule(p, rules)
        enc_re = rule.get("encrypted_regex") if rule else None
        for i, doc in enumerate(docs):
            where = f"{p} (document {i + 1})" if len(docs) > 1 else p
            if not isinstance(doc, dict) or "mac" not in (doc.get("sops") or {}):
                bad.append(f"{where}: no sops metadata, the file is not encrypted")
                continue
            leaks = list(plaintext_leaves(doc, enc_re, False))
            if leaks:
                bad.append(f"{where}: plaintext values at {', '.join(leaks[:5])}")
    for b in bad:
        print(f"sops check: {b}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
