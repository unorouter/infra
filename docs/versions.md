# Upgrading

The index of every pin (charts in `apps/`, images in `infra/` and `databases/`, tofu providers,
the cloud-init HelmChart CRs, k3s, the DR templates) is the
[Dependency dashboard](https://github.com/unorouter/infra/issues?q=is%3Aissue+is%3Aopen+Dependency+dashboard)
issue Renovate keeps current. The policy is `renovate.json`:

- Patch and minor of images and of charts that roll without an operator step merge to `main`
  before 06:00 on Mondays, seven days after the release. ArgoCD rolls the commit like any push.
- Everything else (majors, OpenBao, Teleport, Cilium, ArgoCD, k3s, k0s, the operators' minors,
  tofu providers) waits in the dashboard until its box is ticked. A tick merges it to `main` on the
  next Renovate run, within the hour.
- Renovate never opens a PR. If it ever does (a branch it cannot rebase), merge or close it the
  same day.
- A bump that misbehaves: `git revert` it, then pin the dependency back in `renovate.json`
  with a `matchPackageNames` plus `allowedVersions` rule so the same version is not offered again.

## Steps Renovate cannot take

- **k3s**: the pin in `tofu/variables.tf` is the DR rebuild version only. Running nodes are
  upgraded by swapping the binary, one server at a time, then bump the pin.
- **Cilium and ArgoCD**: the live HelmChart CRs exist only in the cluster. Patch the live CR AND
  accept the bump of `tofu/cloud-init.yaml.tftpl`, `bootstrap/k0s/k0sctl.tmpl.yaml` and
  `scripts/dr.sh` (grouped, one tick). See [cluster.md](cluster.md).
- **OpenBao**: the StatefulSet is `OnDelete`. After the merge delete the pod, then unseal (3 of 5).
- **Teleport**: the auth server chart and the kube agent chart are one group; the auth server
  rolls first, agents reconnect.
- **tofu providers**: the constraint and `.terraform.lock.hcl` change together; run
  `tofu init -upgrade` and `tofu plan` from `tofu/` and `tofu/storage/` before trusting the next apply.
- **Operators (cert-manager, CNPG, Barman plugin)**: read the release notes for CRD changes
  before ticking a minor; a patch merges on its own.
