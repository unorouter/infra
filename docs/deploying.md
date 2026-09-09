# Deploying a service

**A repo with a `k8s/` directory deploys itself**, no commit here.

1. App repo: `k8s/` with Deployment/Service (`namespace: services`), an ExternalSecret on an
   existing OpenBao key, optionally CNPG `Cluster` + `ObjectStore` + `ScheduledBackup`
   (`namespace: databases`), and a `CiliumNetworkPolicy` in `infra/services/networkpolicies.yaml`
   here, because that namespace is default-deny.
2. Push. [apps/appset-services.yaml](../apps/appset-services.yaml) scans the org and creates the
   Application within ~15 min.
3. Push to `main` runs the `GHCR Image` workflow (multi-arch build, then a `deploy(<repo>):
   <sha>` pin commit by `unorouter-ci`; ArgoCD rolls it in 10 to 20 min). Copy the workflow from
   new-api and keep `paths-ignore` on `k8s/**` and `**.md` so pins and docs do not rebuild.

- **Commits by `renovate[bot]` are the weekly dependency bumps** (`renovate.json`, policy in
  [versions.md](versions.md)); ArgoCD rolls them like any push, `git revert` undoes one.
- **Pin images to a git SHA, never `:latest`**: a floating tag changes no manifest, ArgoCD sees
  no diff, nothing deploys.
- **No build secrets anywhere.** Builds use committed public configuration only
  (`NEXT_PUBLIC_*` in `.env.public`); every app gets its secrets at runtime from its
  ExternalSecret. There is no local build path: Actions down means wait.
- **A deploy is done when ArgoCD shows the new image**, never because a push or a workflow
  succeeded.
- Generated apps run under the restricted `apps` AppProject: `services` + `databases` only, no
  cluster-scoped resources.
- **`k8s/` is a deploy gate**: write access to an org repo is write access to the cluster.
