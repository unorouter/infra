# Upgrading

The index of every pin (charts in `apps/`, images in `infra/` and `databases/`, tofu providers,
the Talos and Kubernetes pins in `bootstrap/talos/talconfig.yaml`) is the
[Dependency dashboard](https://github.com/unorouter/infra/issues?q=is%3Aissue+is%3Aopen+Dependency+dashboard)
issue Renovate keeps current. The policy is `renovate.json`:

- Patch and minor of images and of charts that roll without an operator step merge to `main`
  before 06:00 on Mondays, seven days after the release. ArgoCD rolls the commit like any push.
- Everything else (majors, OpenBao, Teleport, Cilium, ArgoCD, Talos, Kubernetes, the operators' minors,
  tofu providers) waits in the dashboard until its box is ticked. A tick merges it to `main` on the
  next Renovate run, within the hour.
- Renovate never opens a PR. If it ever does (a branch it cannot rebase), merge or close it the
  same day.
- A bump that misbehaves: `git revert` it, then pin the dependency back in `renovate.json`
  with a `matchPackageNames` plus `allowedVersions` rule so the same version is not offered again.

## Steps Renovate cannot take

- **Talos**: `talosctl -n <node> upgrade --image factory.talos.dev/installer/<schematic>:<version>`
  one node at a time (A/B image, rolls back on a failed boot), then the `talosVersion` pin.
  **Kubernetes**: `talosctl -n <node11> upgrade-k8s --to <version>` walks every node, then the
  `kubernetesVersion` pin. Both in `bootstrap/talos/talconfig.yaml`, steps in
  `bootstrap/talos/README.md`.
- **ArgoCD**: the upstream manifest pin in `bootstrap/argocd/kustomization.yaml`; ArgoCD applies
  its own upgrade through the root app.
- **OpenBao**: the StatefulSet is `OnDelete`. After the merge delete the pod, then unseal (3 of 5).
- **Teleport**: the auth server chart and the kube agent chart are one group; the auth server
  rolls first, agents reconnect.
- **tofu providers**: the constraint and `.terraform.lock.hcl` change together; run
  `tofu init -upgrade` and `tofu plan` from `tofu/` and `tofu/storage/` before trusting the next apply.
- **Operators (cert-manager, CNPG, Barman plugin)**: read the release notes for CRD changes
  before ticking a minor; a patch merges on its own.
