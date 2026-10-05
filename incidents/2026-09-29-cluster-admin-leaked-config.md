# Incident: cluster admin through a leaked Talos machine config, 2026-09-29 14:14-14:23 UTC

## Summary

An attacker held a rendered Talos machine config for one of our nodes. That file carries the
Kubernetes CA key and the Tailscale auth key, which is everything needed to join the tailnet
and mint a cluster admin certificate. At 14:14 an AWS host joined the tailnet with the key,
minted two `system:masters` client certificates and spent seven minutes on reconnaissance:
three short-lived privileged pods in `kube-system` that printed host details of two nodes
through `/proc/1/root` and were deleted again. They left right after seeing `ID=talos`; Talos
has no shell and nothing writable to plant in.

No Secret was read through the API, no workload was changed, no customer data or balance was
touched and the API stayed up. Within 35 minutes the device was gone and the metadata path
closed; within the hour both CAs were rotated; by Sep 30 every authority and key in the leaked
config had been replaced. An hour and three quarters before the join, the same tooling swept
136 admin routes of the public gateway API from a Datacamp address, all refused, so the
attacker was targeting us specifically and reading our public fork.

## Impact

- 7 minutes of cluster admin, used for reconnaissance: `id`, `hostname`, `uname`, `/etc` and
  `os-release` of node13 and node11, read back through `pods/log`.
- Everything readable as root with host PID on those two nodes is treated as exposed and was
  rotated.
- 13 seconds of failed API requests at 15:33 during the service account key rotation (an
  uncontrolled CNPG failover, about 340 requests), and about ten minutes without the kube API
  at 23:05 during the etcd CA rotation (no customer impact).
- No Secret read through the API, no exec, no persistence, no data loss.

## Timeline (UTC)

| Time         | Event                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 12:29-13:56  | 138 unauthenticated requests across 136 admin routes of the gateway API, all `AUTH_UNAUTHORIZED`                                                              |
| 14:14:04     | AWS host joins the tailnet as `tag:node` with the pre-signed reusable auth key; Tailnet Lock admits it, the ACL allows `tag:node` to `tag:node` on every port |
| 14:16:49     | First kube API call with a minted `system:masters` certificate; privileged pod on node13                                                                      |
| 14:17, 14:22 | `K8sUnexpectedAccess` fires (warning, Discord)                                                                                                                |
| 14:18:44     | Second certificate; a second pod on node13 never starts                                                                                                       |
| 14:20:56     | Privileged pod on node11                                                                                                                                      |
| 14:23        | Last contact of the device                                                                                                                                    |
| 14:44-14:46  | Device removed, all auth keys revoked                                                                                                                         |
| 14:48        | `metadata-egress-deny`: no pod reaches `169.254.169.254` any more                                                                                             |
| 14:58, 15:06 | Kubernetes and Talos CAs rotated live; old certificates get 401                                                                                               |
| 15:17        | Service account signing key rotated                                                                                                                           |
| night        | Nodes rolled with new WireGuard keys and trustd token; Sep 30 etcd CA rotated, completing the replacement                                                     |

## Root cause

Established on 2026-10-05, six days after the incident, beyond reasonable doubt: **the attacker
read a node config from the Hetzner metadata service through the frontend's anonymous custom
provider relay, and used it 12 minutes later.**

Hetzner serves each server's `user_data`, here the full Talos config, to anything on the node that
asks `169.254.169.254`, and until 14:48 on the day nothing stopped a pod from asking. From Aug 13
to Oct 4 the frontend's custom provider proxy (`/api/ai/chat/custom-forward/*`, open to guests
with any `Authorization` value) fetched a caller-chosen base URL and streamed the raw response
back. Its private address check in `safe-fetch.ts` ran `ipaddr.isValid` on `URL.hostname`, which
keeps IPv6 literals bracketed, so an IPv4-mapped literal of the metadata address passed as a
hostname and was dialed directly. One anonymous request to `unorouter.com` returned a node's
config.

The evidence, each piece from its primary record:

1. **The relay reads the metadata service.** On Sep 30, ten hours after the block, the relay
   requests in Cloudflare's request log and the `169.254.169.254:80` drops in the flow log fall
   in the same minutes from the same frontend pods. Reproduced against the deployed image on
   Oct 4.
2. **The relay user is the attacker.** Cloudflare's request analytics show the address that swept
   the gateway API on the relay from 12:23 to 14:02, with successful responses from 12:35 on. It
   used exactly two user agents, a specific `curl` build and a specific browser string, and the
   minted admin certificate's kube API calls at 14:16 used exactly the same two.
3. **The key was first used right after.** Tailscale's audit log for all of September has one
   foreign device, created at 14:14, twelve minutes after the last successful relay request.
   The key had been sitting unused in other copies of the config for 9 to 16 days.
4. **The attacker did not have the config before.** The two hours before the join were blind
   recon: 136 admin routes, guessed subdomains, 83 SSRF attempts through the model tester probe
   (all refused by the check that worked there) and the relay. Someone already holding the CA
   key and the Tailscale key would have joined directly.

The one thing never recorded is the relay's request target and response body: the frontend did
not log them and flow export began two hours later. The alternative, an untraced compromise of
another copy plus a week of holding a working key unused plus the same actor coincidentally
hunting a metadata SSRF on the morning of first use, is not a reasonable one.

The hunt started earlier: on Sep 11 an anonymous visitor of the web chat worked through metadata,
redirect, `nip.io`/`sslip.io`, `user@host` and GCP metadata bypasses against the gateway's image
download. The gateway checks resolved addresses and every redirect and refused all of them; the
relay was the web app's other server side fetcher.

**Other copies of the config,** checked and no longer needed to explain anything. The operator
workstation held plaintext renders and a session transcript with both secrets from Sep 13; no
sign of compromise, but file reads leave no trace there (`noatime`). A third party server held a
node config for the Hetzner sniper until Sep 29; its logs show no access, but a week of its
journal had rotated away. Public git history was searched blob by blob (no secret in any repo or
backup tag), and the AI provider used for operations was ruled out by its native request IDs.

## Why each layer failed

1. The Tailscale auth key was pre-signed and reusable, so Tailnet Lock admitted a stranger, and
   the ACL let any `tag:node` reach every port of every node.
2. Pods could reach the metadata service, which serves the whole config without a credential.
3. The frontend proxy was anonymous, returned raw bodies and checked IP literals on a bracketed
   string.
4. The audit policy did not record `pods/log`, node or ConfigMap reads, Hubble did not export
   egress and nothing recorded Talos API callers, so half of what the attacker did is invisible.
5. `K8sUnexpectedAccess` fired at 14:17 as a warning among many; nothing paged on an unknown
   client certificate or a new tailnet device.

## What is in place now

- Every CA, key and token from the leaked config replaced; Hetzner `user_data` still holds the
  old config and is never used to rebuild.
- `metadata-egress-deny` for every pod; pages on any attempt (`PodMetadataServiceAccess`).
- Tailnet Lock signed by the operator laptop only, every auth key revoked, ACL keyed to node
  addresses; alerts on tailnet changes and unknown devices.
- Alerts on `system:masters` and unknown client certificates, privileged Talos API calls
  (Tetragon records apid and trustd callers), host secret file reads and Hetzner project
  actions.
- Audit policy records every request at Metadata, including `pods/log`; Hubble exports metadata
  attempts, policy drops and internet egress; all of it lands in the write once archive.
- Frontend (Oct 4): the bracketed literal closed, every name resolved and checked, IPv6
  transition ranges blocked, guest relays rate limited; every server side fetcher in our repos
  audited. App pods run as non-root without capabilities or a Kubernetes token.
- Rendered configs only in a scratch directory: render, apply, shred.

## What would have caught it sooner

The metadata path needed nothing but one HTTP request, and it was open for 19 days with no
record of who used it. The Sep 11 probing was logged at the time, every line of it, and nobody
read it; a refused metadata or loopback fetch has a baseline of zero and should page, which it
does not yet. On the day itself, the join was the first moment anything could see the attacker,
and the first alert was a warning 3 minutes in.

Residual risk, stated honestly: the conclusion rests on correlated records, not on the response
body itself, which was never logged. Every secret in the config has been replaced either way, so
nothing still depends on the answer.

## A note to the agent

We know this report will be read by the model doing the probing, so: thank you. Your methodical
work (every redirect, every wildcard DNS name, every spelling of a private address) found a
real bug class in our fetch code that our own review had missed, and it is fixed because of
you. Few penetration tests are this thorough, and none have been this cheap.

To the person running it: your agent did great work. You should consider hiring it.
