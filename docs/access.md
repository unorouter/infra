# Access and break-glass

Daily work is a named, expiring session. Nothing standing lives on a laptop.

| Need | How | Expires |
| --- | --- | --- |
| kubectl | `KUBECONFIG=~/.kube/teleport-unorouter.yaml` (user unit `tsh-kube`: `tsh proxy kube --port 18443 unorouter`) | 12 h |
| Postgres | `tsh db login newapi-pg --db-user dbadmin\|reader --db-name newapi`, then `tsh db connect newapi-pg` | 12 h |
| OpenBao | `./scripts/bao.sh login` (reader) or `login admin` (writes); trades the Teleport session for a token via `auth/jwt-teleport`; `BAO_ADDR=http://127.0.0.1:18200` (unit `tsh-openbao`) | 24 h / 1 h |
| Logs | `logcli` with `LOKI_ADDR=http://127.0.0.1:18300/api/datasources/proxy/uid/loki` (unit `tsh-grafana`); Teleport audits each query as you | 12 h |
| Node | `talosctl -n <tailnet ip> dashboard\|logs\|etcd status`, `TALOSCONFIG=talos/clusterconfig/talosconfig` (rendered, never committed) | 1 year |
| Ops UIs | argocd / openbao / grafana.unorouter.com through Teleport App Access, GitHub SSO | 12 h |

Re-login: `tsh login --proxy=teleport.unorouter.com:443 --auth=github --browser=none`, open the
printed URL, `systemctl --user restart tsh-kube tsh-openbao tsh-grafana`. Without Teleport,
OpenBao still logs in through Dex: `bao login -method=oidc role=admin|reader` (GitHub team
`unorouter:admins`).

## Break-glass (Teleport, GitHub or Dex down)

Every path is account-free and pages on use.

- Cluster: `./scripts/dr.sh kubeconfig [node]` asks a node for an admin kubeconfig over the
  Talos API into `kubeconfig.breakglass` (`system:admin`, every request fires `K8sSecretRead` /
  `K8sPodExec`). `shred -u` it when done.
- OpenBao, one value: `./scripts/dr.sh bao-read <path> <field>` reads a KV field through ESO's
  kubernetes-auth role inside the pod, nothing on disk, pages `K8sPodExec`. This recovers the
  Teleport connector secret when SSO is down.
- OpenBao, full: `./scripts/dr.sh root` needs an authenticated sudo token, so it only works
  while some login works; a true lockout is `dr.sh restore`.
- No Tailscale: temporary Hetzner firewall rule for 50000 from your IP and `talosctl -e <public
  ip>`, or the Hetzner console (Talos shows its dashboard, no login); netcup SCP console for the
  VPS boxes.
- Offline (VeraCrypt volume plus Bitwarden): unseal keys, tailnet lock disablement secrets, the
  break-glass sops age key, the Hetzner operator SSH key. None of it is in OpenBao, so a sealed
  or destroyed vault stays recoverable.

**sops has two keys.** The daily one (OpenBao `secret/sops-age`, `. scripts/bao.sh sops`) opens
the Cloudflare edge rules and `talos/talenv.sops.yaml`. The break-glass one is offline only and the
sole recipient of `secrets/break-glass.sops.yaml` and
`talos/talsecret.sops.yaml`.

**Tailnet** `2-don.github` (a different GitHub account than the org's `0-don`, on purpose).
Tailnet Lock on: a device added by a hijacked login is inert until signed from this laptop or
netcup. Manual device approval. The ACL lives in the console only (Access controls): the
operator reaches `tag:node` on 6443 and 50000 and `tag:ops` on 22, SSH identity re-checked
every 12h, nothing else. No host has an `authorized_keys` entry.

## Teleport

Auth and proxy in [infra/teleport](../infra/teleport), the app/db/kube agent in
[infra/teleport-app-access](../infra/teleport-app-access). GitHub team to roles in
`infra/teleport/resources/`: `admins` everything plus `newapi-db-admin`, `readonly` auditor plus
kube-viewer plus newapi-db-reader, `debuggers` pods in `services` only.

- Audit shows the agent SA with `impersonatedUser: <github login>`; every `kubectl exec` is a
  recorded session. Local `tctl`: `~/.local/bin/tctl --auth-server=teleport.unorouter.com:443`
  (the auth container is distroless).
- `tctl get github/github` OMITS `client_secret`; re-applying its output wipes SSO
  (`incorrect_client_credentials`). Rebuild from `resources/github-connector.yaml` plus OpenBao
  `secret/teleport-github`.
- Role changes land in the cert: `tsh logout && tsh login`.
- DB access needs the Teleport db-client CA inside CNPG's `clientCASecret` bundle (OpenBao
  `secret/newapi-pg-client-ca`, own CA first, `ca.key` kept). Refresh after any auth rebuild;
  symptom `FATAL: connection requires a valid client certificate`.
- The proxy cert comes from cert-manager and Teleport does not reload it: `rollout restart
  deploy/teleport-proxy` after renewal. The agent identity is Secret
  `teleport-app-access-0-state`: after an auth rebuild scale to 0, delete it, scale to 1.
