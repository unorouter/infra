#!/usr/bin/env bash
# Source this before any `sops -d` of a DAILY file (Cloudflare edge rules): the age key comes
# from OpenBao through the Teleport app proxy and stays in this shell's memory.
#   . scripts/sops-env.sh
# The reader role (24h) is enough here; only openbao-ci-auth.sh and kv patches need `bao-login.sh admin` (1h).
# Break-glass files (secrets/openbao-init, secrets/tailnet-lock) use the other key, which is
# only on the VeraCrypt volume: export SOPS_AGE_KEY_FILE=/run/media/veracrypt1/unorouter/sops-age-keys.txt
export PATH="$HOME/.local/bin:$PATH"   # bao, tsh, tctl live there
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:18200}"
bao token lookup >/dev/null 2>&1 || { echo "!! no OpenBao session: systemctl --user start tsh-openbao; ./scripts/bao-login.sh (24h, read-only; `bao-login.sh admin` for writes, 1h)" >&2; return 1 2>/dev/null || exit 1; }
export SOPS_AGE_KEY=$(bao kv get -field=key secret/sops-age)
unset SOPS_AGE_KEY_FILE
echo "sops daily key loaded from OpenBao"
