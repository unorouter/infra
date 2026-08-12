# Incident: api.unorouter.com degraded, 2026-08-12 06:00-09:00 UTC

## Summary (customer-facing)

Between roughly 06:00 and 09:00 UTC on 2026-08-12, a share of requests to
api.unorouter.com timed out at our edge provider (Cloudflare error 524 or client
timeouts). At the worst point, roughly half of incoming API requests did not reach our
backend. The API service itself was healthy the entire time: requests that got through
were answered normally, and no data was lost or corrupted. The failure was isolated to
one of the two edge tunnel connectors that carry traffic from Cloudflare into our
infrastructure; it had silently degraded while still reporting itself healthy. It was
removed at 08:56 UTC and traffic recovered immediately after. Concrete measures against
this failure class are listed at the end and were deployed the same day.

## Impact

- Window: ~06:00 to ~09:00 UTC (about 3 hours, intermittent).
- Magnitude: origin-side request volume dropped from a ~2,900/15min baseline to a floor
  of ~1,100-1,600/15min, i.e. up to ~50-60% of API requests failed to complete during
  the worst buckets. Failures were intermittent per request, not a hard outage: retries
  could succeed at any point in the window.
- The same-day comparison rules out organic traffic dips: the previous day's identical
  window shows volume RISING from 4.5k to 6.6k per 30 minutes.
- No data loss. Requests that reached the backend were processed normally; backend
  error rates stayed at their normal baseline throughout.

## What the API service itself did (why the origin is exonerated)

- new-api pods: zero restarts across the window, normal CPU/memory.
- In-cluster probes of the exact origin endpoint during the peak: 8/8 responses in
  0.10-0.16s while the public hostname was timing out externally.
- Postgres healthy (30 connections, no lock waits).
- The origin saw FEWER requests, not more errors: traffic died before reaching it.

## Root cause

Public traffic enters exclusively through Cloudflare Tunnel connectors (cloudflared)
running in the cluster. One of the two replicas (5 days old) entered a degraded state in
which its QUIC connections to the Cloudflare edge stalled: the replica stayed registered
and kept passing its readiness endpoint, so the edge continued routing a share of
requests to it, where they hung until the client gave up. cloudflared logged this only
as `Incoming request ended abruptly: context canceled` (1,578 occurrences in one
5-minute sample), a signal that existed nowhere but pod logs.

Evidence pinning the specific replica:

- Two independent CI failures (08:06 and 08:46 UTC) show OpenBao timing out reading the
  request from exactly that replica's connection (`10.42.2.35`), while the same request
  path succeeded via other replicas.
- A ~4KB POST from a fresh pod on the same node to the same origin completed in 0.028s,
  ruling out node networking and MTU.
- Deleting the replica at 08:56 UTC resolved the failing paths immediately; origin
  request volume recovered in the 09:00 bucket.

The precise trigger of the QUIC degradation at ~06:00 is not known; the replica's logs
were destroyed when it was deleted during remediation. The prevention below removes the
dependency on that answer.

## Contributing factors

- Only 2 tunnel replicas existed; one degraded replica meant roughly half of edge
  traffic stalled, matching the observed ~50% loss.
- The tunnel had no metrics scraping and no alerting; the only error signal lived in pod
  logs nobody watches.
- Readiness (`/ready`) only reflects "connections registered", not "requests succeed",
  so Kubernetes had no reason to restart the degraded pod.
- A concurrent, unrelated frontend memory incident produced its own 524s and consumed
  the first hours of diagnostic attention.

## Timeline (UTC, 2026-08-12)

- ~06:00 - origin API request volume begins dropping; intermittent client timeouts start
- 08:02 - user-visible 524 on the frontend host confirms edge-side timeouts
- 08:06 - CI secret fetch times out through tunnel replica `zd22b` (first hard evidence)
- 08:10 - origin verified healthy from inside the cluster (0.1s) while public host fails
- 08:20 - cloudflared scaled 2 to 3 replicas (one per node)
- 08:46 - second CI failure pins `zd22b` again
- 08:56 - `zd22b` deleted; fresh replica registers
- 09:00 - origin request volume recovers to baseline; API stable from here

## Prevention (deployed 2026-08-12)

1. **Tunnel protocol switched from QUIC to http2.** The degraded connections were QUIC
   (UDP). http2 keeps the tunnel on TCP, removing the entire failure class observed.
2. **Daily rolling replica recycling** (04:30 UTC CronJob, one replica at a time, 2 of 3
   always serving). The degraded replica was 5 days old; process age is the common
   factor in this cluster's degradation incidents. No replica gets old now.
3. **Tunnel error-rate alerting**: cloudflared metrics are now scraped
   (PodMonitor :2000) and `TunnelRequestErrorsHigh` pages at >1 errored req/s for 10m
   (baseline ~0.1/s; this incident ran at ~5/s). The signal that required log-grepping
   is now a Discord page.
4. **3 replicas, one per node** (was 2), bounding a single degraded replica's blast
   radius to ~1/3 of traffic even before it is recycled.
5. **cloudflared upgraded 2026.7.0 to 2026.7.3.**

Residual risk, stated honestly: all public traffic still enters through Cloudflare
Tunnel. A Cloudflare-side outage remains a single point of failure. A direct (DNS-only)
fallback hostname is possible but exposes origin server IPs, trading DDoS posture for
edge independence; deliberately not done without an explicit decision.
