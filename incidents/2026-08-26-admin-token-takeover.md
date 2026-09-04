# Incident: admin API token takeover, 2026-08-26 19:53-20:36 UTC

## Summary

An attacker obtained the administrative personal access token (PAT) for the new-api gateway
and used it for 43 minutes. They modified 15 customer accounts, changed the root admin
password, cycled two-factor authentication on the admin account to clear a verification gate,
and read four upstream provider keys. They returned once the next morning (04:13-05:07 UTC)
and were refused on all but one request.

No customer balance was taken; every affected account reconciles exactly against what its
owner paid. The API served traffic normally throughout. The intrusion was noticed because the
attacker's password change revoked every admin session and logged the operator out, 37 minutes
after the first request. Nothing was watching the audit log.

## Impact

- 15 customer accounts modified; the attacker signed in to 11 of them.
- 4 upstream provider keys read; three rotated, one channel deleted.
- 25 customer API keys viewed; all deleted.
- Root admin password changed, admin locked out for 19 minutes.
- Turnstile toggled 36 times to weaken login defences.
- Passwords set on 4 accounts, not discovered until 2026-08-28 (below).
- No balance movement, no data loss, no downtime.

## Root cause

The PAT was exposed outside the platform, not obtained through a vulnerability in the gateway,
the database or any host we run. Admin work using that token ran continuously until 19:53:38;
the attacker's first request arrived at 19:53:39. A credential stolen from storage has no
reason to correlate to the second with a live session. Two checks rule out the alternatives:
the PAT appears in no file predating the attack on the operator workstation, and all 203
provider keys sat in plaintext in a config file on that same workstation, which an attacker
with file access would have taken instead of spending 43 noisy minutes to reach four.

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 19:53:39-41 | 4x `POST /api/channel/:id/key`, all refused (403). First attacker trace. |
| 19:55:16 | Channel copy, first successful action |
| 19:55-20:30 | 32 `user.update` operations across 15 accounts + admin |
| 19:56-20:35 | 36 `option.update` operations, mostly Turnstile toggles |
| 20:07:29-20:08:03 | 9 accounts taken over in 34 seconds |
| 20:22-20:36 | 11 2FA events on the admin account, 3 full setup/enable/disable cycles |
| 20:30:36 | 19 admin sessions revoked; operator logged out, attack noticed |
| 20:30:38 | Admin password changed; attacker's first interactive login 4 seconds later |
| 20:36:03 | Passes security verification with their own 2FA enrolment |
| 20:36:05-11 | 4 upstream provider keys read |
| 20:36:16 | 2FA force-disabled. Last action of the main intrusion. |
| 20:49 | Operator regains access with a reset password |
| 08-27 04:13-05:07 | Attacker returns: 14 refused requests, one login to a customer account, one key read |

122 actions from one IPv6 tunnel-broker address plus one from China, a single generic Chrome
user agent throughout.

## How the 2FA gate was cleared

Reading a channel key requires `SecureVerificationRequired`, which a PAT alone cannot satisfy;
that is why the four 19:53 attempts returned 403. The attacker changed the admin password,
logged in, enrolled their own 2FA, passed verification with it, and force-disabled it after.
Each cycle bumped `auth_version`, which also invalidated the real admin's sessions. The gate
worked as designed; the attacker took ownership of the second factor.

## Found later

`user.update` logs only the target account, not which fields changed. A point-in-time restore
of the pre-attack database (2026-08-28) compared field by field against production showed the
attacker had set passwords on four accounts assessed as untouched, two of which had no password
before, creating a login path their owners would never check. All four were restored to their
pre-attack values. The same comparison across all 23,966 accounts, 27,464 tokens and 3,643
channels confirmed zero role, status, group, OAuth, token-ownership or `base_url` changes, and
all auth options back to their original values.

## Response

Same evening: admin password reset, attacker sessions revoked, stolen tokens deleted, provider
keys rotated. Since:

- PAT revocation works: `auth_version` bumps blank `access_token` in the same statement,
  across 13 revocation sites. Before this a password reset did not kill a PAT.
- Credential-changing routes behind `SessionOnly()`, locked by a test.
- `POST /api/user/manage` refuses a PAT for `delete`, `promote`, `demote` and `disable`.
- Service credentials replaced: the BFF holds no privileged token; bot and sync tokens
  regenerated and scoped to 4 routes and 2 handlers.
- `reader` database role lost `pg_read_all_data`; secret columns are no longer readable.
- Audit trail protected against deletion; `TRUNCATE` revoked from the app role.
- Security alerting on the audit log, including refused channel-key reads. Replayed against
  this incident it fires at 19:53:39, 42 minutes before the breach.

## What would have caught it sooner

Detection depended on the attacker doing something disruptive enough to be felt. Of 83
actions, 79 ran on the stolen PAT alone; only the four key reads needed a session, because
`SecureVerificationRequired` refuses a bare PAT there. The attacker changed the admin password
only because the keys were gated. Had they wanted just the customer accounts, nothing would
have logged the operator out and the intrusion would have finished unobserved. The one control
that worked is also the only reason the attack became visible.

The four refused key reads at 19:53 were logged at the time and nothing read them. That route
has a measured baseline of zero, so a single refusal is now a page. Volume-based alerting could
not have helped: the attacker's peak was 4 refusals per 5-minute bucket against a normal p95
of 34, so the alerts key on shape and first contact, not on count.
