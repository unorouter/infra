# Incident: etcd quorum loss, 34 minutes without database writes, 2026-07-23

## Summary

`TF_VAR_ha_node_type=cpx22 tofu apply -replace=hcloud_server.node2` changed both nodes' server
type through the variable override, so the plan replaced node2 and node3 together and node3 was
destroyed undrained. etcd lost two of three members, the apiserver went down and CNPG could not
promote: every login and write returned "Database error" for about 34 minutes. Public reads kept
serving from node1. No data lost. Self inflicted.

## Lessons

- Never combine a variable override that widens the blast radius with `-replace` or
  `-auto-approve`. Plan, read the add, change and destroy lines, one node per apply.
- Recovery: `k3s server --cluster-reset` on the survivor with the same `--node-ip` and
  `--advertise-address` as the unit, other nodes stopped first, rejoin one at a time with a
  wiped `server/db`. The procedure lives in `bootstrap/dr/README.md`.
