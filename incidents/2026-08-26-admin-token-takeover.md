# Incident: admin API token takeover, 2026-08-26 19:53-20:36 UTC

## Summary (customer-facing)

On 2026-08-26 an attacker obtained the administrative personal access token (PAT) for
the new-api gateway and used it for 43 minutes, from 19:53:39 to 20:36:16 UTC. In that
window they modified 15 customer accounts, changed the root admin password, cycled
two-factor authentication on the admin account to clear a verification gate, and read
four upstream provider keys. They returned once the following morning (04:13-05:07 UTC)
and were refused on all but one request.

No customer balance was taken. Every affected account reconciles exactly against what
its owner paid. The API served traffic normally throughout; there was no downtime.

The intrusion was noticed because the attacker's password change revoked every admin
session at 20:30:36 UTC and logged the operator out. Nothing was watching the audit log
at the time, so the only signal was the side effect of being locked out, 37 minutes
after the attacker's first request and 6 seconds before the provider keys were within
reach.

## Impact

- 15 customer accounts modified; the attacker signed in to 11 of them.
- 4 upstream provider keys read (channels 11720, 8871, 8475, 11678). Three have since
  been rotated, one channel deleted.
- 25 customer API keys viewed; all have been deleted.
- Root admin password changed and admin locked out for ~19 minutes.
- Turnstile (bot protection) toggled 36 times to weaken login defences.
- Passwords set on 4 accounts that were not discovered until 2026-08-28 (see below).
- No balance movement on any account. No data loss. No downtime.

## Root cause

The admin PAT was exposed outside the platform. It was not obtained through a
vulnerability in the gateway, the database, or any host we run.

The strongest evidence is timing. Admin work using that token ran continuously from
14:39 to 19:53:38 UTC (1,882 PAT-authenticated channel updates). The attacker's first
request arrived at 19:53:39 UTC, one second later, and the owner kept working unaware
until 19:54:10. A credential stolen from storage has no reason to correlate to the
second with a live session.

Two independent checks support this and rule out the alternatives:

- The PAT appears in ZERO files predating the attack anywhere on the operator
  workstation. An infostealer scraping the filesystem could not have taken it.
- All 203 upstream provider keys sit in plaintext in `new-api-sync/config.yml` on that
  same workstation. An attacker with file access would have taken that file and had
  every provider key instantly. Instead they spent 43 noisy minutes inside the platform
  to reach four keys, and their first four requests to `/api/channel/:id/key` were
  refused with 403. That is someone probing an unfamiliar credential.

A GitHub account flag on 2026-08-17 was initially suspected as related. It is not: the
four "suspicious" logins GitHub flagged resolve to the operator's own IP block
(88.130.x.x), the same address used for legitimate token operations that day. That flag
is a false positive and no credential leaked through it.

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 14:39-19:53:38 | Operator runs 1,882 PAT-authenticated channel updates |
| 19:53:39-19:53:41 | 4x `POST /api/channel/:id/key`, all refused (403). First attacker trace. |
| 19:55:16 | Channel copy (source 11720), first successful action |
| 19:55:34-20:30:38 | 32 `user.update` operations across 15 accounts + admin |
| 19:56:26-20:35:51 | 36 `option.update` operations, mostly Turnstile toggles |
| 20:07:29-20:08:03 | Bulk account takeover: 9 accounts in 34 seconds |
| 20:22:47-20:36:16 | 11 2FA events on the admin account: 3 full setup/enable/disable cycles |
| 20:30:36 | 19 admin sessions revoked (`admin_user_update`). **Operator logged out; this is how the attack was noticed.** |
| 20:30:38 | Admin password changed |
| 20:30:42 | Attacker's first interactive login (4 seconds later) |
| 20:36:03 | Passes "Universal security verification (method: 2FA)" using their own enrolment |
| 20:36:05-20:36:11 | **4 upstream provider keys read** via session auth |
| 20:36:16 | 2FA force-disabled (cleanup). Last action of the main intrusion. |
| 20:49:06 | Operator regains access with a reset password (18 minutes locked out) |
| 21:51:25 | Operator enrols new 2FA on the admin account |
| 08-27 04:13-05:00 | Attacker returns, 14 requests, all `AUTH_UNAUTHORIZED` |
| 08-27 05:04:59 | Logs in to account 4167 from 116.162.233.137 (China) |
| 08-27 05:07:46 | Reads one customer API key. Final attacker action. |

Attack totals: 121 actions from `2a01:d0:ffff:23e1::2` (NetAssist, a Ukrainian tunnel
broker) plus 1 from a Chinese address. Single user agent throughout, generic Chrome on
Linux, carrying no locale information.

## How the 2FA gate was cleared

Reading a channel key requires `SecureVerificationRequired`, which a PAT alone cannot
satisfy: the four attempts at 19:53 returned 403 precisely because of it.

The attacker's answer was to change the admin password (20:30:38), log in (20:30:42),
then enrol their own 2FA on the account, pass the verification with it (20:36:03), and
force-disable it afterwards. Each setup/disable cycle bumped `auth_version`, which also
invalidated the real admin's sessions as a side effect. The gate worked as designed; the
attacker went around it by taking ownership of the second factor.

## What was missed at the time, and found later

The audit trail recorded every action, but `user.update` logs only the target account,
not which fields changed. That gap hid the most serious finding for two days.

On 2026-08-28 a point-in-time restore of the pre-attack database (base backup
2026-08-26 03:36 plus 1,024 WAL segments, replayed to 18:59:59) allowed a field-level
comparison against production. It showed the attacker had **set passwords on four
accounts** that had been assessed as untouched: 19111, 20668, 21607, 23215. Two of them
(19111, 23215) had no password at all before, so a login path was created that their
owners would never think to check. Those passwords were still live.

All four were restored to their exact pre-attack values on 2026-08-28. The attacker's
hashes were backed up to `_bak_attacker_pw_20260828` first.

The same comparison, run across all 23,966 pre-existing accounts, confirmed:

- Zero role, status or group changes anywhere.
- Zero OAuth bindings added or altered on any pre-existing account.
- Zero token ownership or key changes across 27,464 tokens.
- Zero `base_url` changes across 3,643 channels (no traffic was ever redirected).
- All auth-related options identical, including `TurnstileCheckEnabled` back at `true`.

A second snapshot replayed to 03:39:59 confirmed nothing happened in the 15 hours before
the attack either: 6 accounts changed, all ordinary self-service email or Discord links.

## Response

Same evening: admin password reset, all attacker sessions revoked, stolen tokens
deleted, provider keys rotated.

Since:

- PAT revocation now works. `IncrementUserAuthVersionWithTx` blanks `access_token` in
  the same statement as the `auth_version` bump, across 13 revocation sites. Before this
  a password reset did not kill a PAT.
- Credential-changing routes moved behind `SessionOnly()`, locked by
  `router/session_only_test.go`.
- `POST /api/user/manage` refuses a PAT for `delete`, `promote`, `demote` and `disable`
  (2026-08-28). The prior guard covered only the bot token, leaving the attacker's exact
  method open.
- Service credentials replaced: the BFF no longer holds any privileged token, the bot
  and sync tokens were regenerated post-attack and are scoped to 4 routes and 2 handlers
  respectively.
- `reader` database role lost `pg_read_all_data`; secret columns are no longer readable.
- Audit trail protected against deletion; `TRUNCATE` revoked from the app role.
- Security alerting deployed, including `ChannelKeyReadRefused`. Replayed against this
  incident it fires at 19:53:39, **42 minutes before** the breach and 103 minutes before
  the keys were read.

## What would have caught this sooner

Detection depended on the attacker doing something disruptive enough to be felt. Locking
the operator out was that thing, and it came 37 minutes in, after 15 accounts had already
been taken over.

The uncomfortable part is how narrow that was. Of 83 actions, **79 ran on the stolen PAT
alone**: every account takeover, all 36 Turnstile toggles, the channel copy. Only 4
needed a session, the key reads at 20:36:05-20:36:11, because
`SecureVerificationRequired` refuses a bare PAT on that route. That refusal is why the
19:53 attempts returned 403.

So the attacker changed the admin password only because the keys were gated. Had he
wanted just the customer accounts, or had he read the keys last, nothing would have
logged the operator out and the intrusion would have finished unobserved. The one
control that worked as designed is also the only reason the attack became visible, which
is a fragile place to be: it depends on the attacker wanting the one thing that is
properly protected.

That matters more given what happened next. The audit trail was destroyed the following
day and recovered only from S3 point-in-time backups. Without the logout prompting an
investigation that same evening, the forensic record would have been gone before anyone
looked at it.

The four refused key reads at 19:53 were logged at the time and nothing read them. They
were the first and best signal, 42 minutes ahead of any damage, and 37 minutes ahead of
the logout that actually raised the alarm. The alert that now
watches that route has a measured baseline of zero: eight such rows exist in the entire
9.3M-row history, four of them this attacker and four the operator during the response.

Volume-based alerting could not have helped. The attacker's peak was 4 refusals per
5-minute bucket against a normal p95 of 34.
