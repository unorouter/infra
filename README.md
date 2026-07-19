# infra

Config-as-code for the unorouter revenue stack on k3s (Hetzner CAX31 ARM, single node).
Full plan + rationale: `../backup/k3s-migration-plan.md`.

Stack: k3s + Cilium (CNI + Gateway API hostNetwork + Hubble) + ArgoCD + CloudNativePG
(Barman Cloud plugin -> Hetzner S3) + SOPS/age + Dagger->ghcr (thin GHA wrapper).
TLS: Cloudflare Origin cert on the Gateway (NOT cert-manager/ACME - cilium#45705).

## One-time prerequisites

1. **age key** (exists): `~/.config/sops/age/keys.txt`. BACK IT UP OFFLINE. Loss = all
   encrypted secrets unrecoverable.
2. **Hetzner Cloud API token**: Cloud Console -> project -> Security -> API tokens (rw).
3. **Hetzner S3 credentials**: Cloud Console -> Object Storage -> generate credentials
   (NOT api-creatable). Region fsn1.
4. **Tailscale**: reusable auth key from the admin console. ACL: autoApprover for
   `10.42.0.0/16` (pod CIDR), see plan.
5. **Cloudflare Origin cert**: CF dashboard -> SSL/TLS -> Origin Server -> create (15y,
   `*.unorouter.com`). Becomes the Gateway TLS secret later.

## Secrets for tofu (never plaintext on disk)

```sh
cat > tofu/secrets.sops.yaml <<'EOF'
TF_VAR_hcloud_token: "..."
TF_VAR_s3_access_key: "..."
TF_VAR_s3_secret_key: "..."
TF_VAR_tailscale_authkey: "tskey-auth-..."
TF_VAR_operator_cidr: "x.x.x.x/32"
EOF
sops --encrypt --in-place tofu/secrets.sops.yaml
```

`operator_cidr` lives in sops (public repo, home IP stays private); switch it to the
tailnet CIDR `100.64.0.0/10` once Tailscale is up. Non-secret vars ->
`tofu/terraform.tfvars` (committed): `ssh_public_key` only.

## Bootstrap order (P0)

```sh
# 1. infra
cd tofu && tofu init
sops exec-env secrets.sops.yaml 'tofu plan'
sops exec-env secrets.sops.yaml 'tofu apply'   # manual only, never CI

# 2. kubeconfig
ssh root@<node_ip> cat /etc/rancher/k3s/k3s.yaml > ../kubeconfig
sed -i 's/127.0.0.1/<node_ip>/' ../kubeconfig
export KUBECONFIG=$PWD/../kubeconfig
kubectl get nodes   # NotReady until Cilium lands - expected

# 3. Gateway API CRDs (standard channel), then Cilium
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium -n kube-system -f ../infra/cilium/values.yaml
cilium-cli status --wait

# 4. VERIFY GATE (curl, never Programmed=True - cilium#42786 hostNetwork status bug)
# deploy a test Gateway+HTTPRoute, then:
curl -sv http://<node_ip>/ -H 'Host: test.example'
# + Hubble flows visible + a deny CiliumNetworkPolicy actually denies

# 5. ArgoCD + age key + root app
kubectl create namespace argocd
kubectl apply -k ../bootstrap/argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
# set repoURL in bootstrap/root-app.yaml, then:
kubectl apply -f ../bootstrap/root-app.yaml
```

## Non-negotiable gotchas (from the plan's reanalysis - all sourced)

- Gateway exposure = hostNetwork mode ONLY (nodeIPAM+Gateway drops external traffic,
  cilium#44187). Verification gates on CURL, never on `Programmed=True` (#42786).
- HTTPRoute retry is INERT in Cilium (#46432). Don't design around it; timeouts are fine.
- cert-manager ACME is blocked by Cilium Opaque-secret pre-creation (#45705) -> CF Origin cert.
- CNPG: use the Barman Cloud PLUGIN (in-tree deprecated 1.26); Hetzner-S3 needs the
  boto3 checksum env workaround + path addressing; test-restore from the REAL bucket is a
  HARD GATE before any DNS flip (restore-path failure report: cloudnative-pg#6645).
- Before `k3s-uninstall`/`killall`: manually delete cilium_host/cilium_net/cilium_vxlan
  interfaces or the host loses networking.
- new-api master stays replicas:1 forever (migration/jobs singleton, NODE_TYPE unset).
