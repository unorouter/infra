# Access and break-glass

Daily work is a named, expiring session. Nothing standing lives on a laptop.

| Need | How | Expires |
| --- | --- | --- |
| kubectl | `KUBECONFIG=~/.kube/teleport-unorouter.yaml` (systemd user unit `tsh-kube` runs `tsh proxy kube --port 18443 unorouter`) | 12 h cert |
| Postgres | `tsh db login newapi-pg --db-user dbadmin\|reader --db-name newapi`, then `tsh db connect newapi-pg` | 12 h cert |
| OpenBao | `./scripts/bao-login.sh` (reader, kv-read) or `./scripts/bao-login.sh admin` (writes); trades the Teleport session for a token via `auth/jwt-teleport`, `BAO_ADDR=http://127.0.0.1:18200` (unit `tsh-openbao`) | 24 h / 1 h |
| Node shell | `ssh root@<tailscale ip>` (Tailscale SSH, no key) | identity check every 12 h |
| Ops UIs | argocd / openbao / grafana.unorouter.com through Teleport App Access, GitHub SSO | 12 h |

Re-login: `tsh login --proxy=teleport.unorouter.com:443 --auth=github --browser=none`, open the
printed URL, then `systemctl --user restart tsh-kube tsh-openbao`.

OpenBao has no Teleport dependency of its own: `bao login -method=oidc role=admin|reader`
(Dex, GitHub team `unorouter:admins`) issues the same tokens when the JWT app is unavailable.

**Break-glass** (Teleport, GitHub or Dex down). Each path is account-free and pages on use:

- Cluster: `./scripts/dr.sh kubeconfig [node]` pulls `/etc/rancher/k3s/k3s.yaml` over Tailscale
  into `kubeconfig.breakglass`. It authenticates as `system:admin`, so every request fires
  `K8sSecretRead` / `K8sPodExec`. `shred -u` it when done.
- OpenBao: `./scripts/dr.sh root` runs `generate-root` with three unseal keys. Fires
  `OpenBaoRootUsed`. `bao token revoke` it when done.
- No Tailscale: Hetzner console for the nodes, netcup SCP console for the VPS boxes.
- Offline (VeraCrypt volume plus Bitwarden): unseal keys, tailnet lock disablement secrets,
  break-glass sops age key, the Hetzner operator SSH key. Nothing of this is in OpenBao, so a
  sealed or destroyed vault stays recoverable.

**sops has two keys**: the daily one lives in OpenBao `secret/sops-age` and opens the Cloudflare
edge rules (`. scripts/sops-env.sh`, or `apply.sh` fetches it itself); the break-glass one is
offline only and is the sole recipient of `secrets/openbao-init.sops.yaml` (unseal keys) and
`secrets/tailnet-lock.sops.yaml`.

**Tailnet** `2-don.github` (a different GitHub account than the org's `0-don`, on purpose):
Tailnet Lock on, so a device added by a hijacked login is inert until signed from this laptop or
netcup; manual device approval; ACL in [infra/tailscale/acl.hujson](../infra/tailscale/acl.hujson)
grants only the operator and the `node`/`ops` tags, SSH is `action: check` with `checkPeriod:
12h`. No host has an `authorized_keys` entry.

### Teleport

Auth and proxy in-cluster ([infra/teleport](../infra/teleport)), the app/db/kube agent in
`teleport-agent` ([infra/teleport-app-access](../infra/teleport-app-access)). GitHub team to roles
in `infra/teleport/resources/`: `admins` everything plus `newapi-db-admin`, `readonly` auditor +
kube-viewer + newapi-db-reader, `debuggers` pods in `services` only. Someone outside the org
gets the authorize page and then nothing.

- Audit shows the agent SA with `impersonatedUser: <github login>`; every `kubectl exec` is a
  recorded session. `tctl` works locally: `~/.local/bin/tctl --auth-server=teleport.unorouter.com:443`.
- `tctl get github/github` OMITS `client_secret`; re-applying its output wipes SSO
  (`incorrect_client_credentials`). Rebuild from `resources/github-connector.yaml` plus OpenBao
  `secret/teleport-github`. The auth container is distroless, so use local `tctl`.
- Role changes land in the cert: `tsh logout && tsh login` before they take effect.
- DB access needs the Teleport db-client CA inside CNPG's `clientCASecret` bundle (OpenBao
  `secret/newapi-pg-client-ca`, own CA first, `ca.key` kept). Refresh it after any auth rebuild,
  symptom `FATAL: connection requires a valid client certificate`.
- The proxy cert comes from cert-manager; Teleport does not reload it, `rollout restart
  deploy/teleport-proxy` after renewal. The agent's identity is Secret
  `teleport-app-access-0-state`: after an auth rebuild, scale to 0, delete it, scale to 1.
