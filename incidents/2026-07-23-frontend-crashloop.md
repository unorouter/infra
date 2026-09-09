# Incident: frontend crashloop for about eight hours, 2026-07-23 night

## Summary

`unorouter-env` lacked `INTERNAL_API_URL` (the old compose deployment injected it outside the
env file), so server side calls fell back to the public API hostname: pod to Cloudflare edge to
tunnel and back in. Cloudflare's L3/4 auto mitigation then dropped the node's IPv4 mid TLS
handshake for this zone only, `/api/ops/health` hung past five seconds, and the liveness probe
on that same endpoint killed both replicas all night. Site 502, API fine.

## Lessons

- Liveness is `tcpSocket` only. Killing a pod never fixes a slow external dependency; readiness
  keeps the dependency check.
- In-cluster traffic stays in the cluster: `INTERNAL_API_URL=http://new-api.services.svc.cluster.local:3000`.
- When migrating a service, diff `docker inspect <c> .Config.Env` against the Kubernetes Secret,
  not only the env file.
