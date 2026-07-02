# AWS Self-Managed Kubernetes — Hub & Spoke Terraform

Two independent `kubeadm` clusters on EC2, connected over a Transit Gateway:

- **hub** — small cluster whose only job is running Argo CD.
- **spoke** — your actual workload cluster (what the old single-cluster setup used to be). Managed remotely by the hub's Argo CD; runs no Argo CD itself.

Terraform's job stops at "clusters exist, are networked together, and are alive" (nodes Ready, CNI + CCM installed, and — hub only — Argo CD installed). Actual `Application`/`AppProject` manifests, and registering the spoke as a remote cluster inside Argo CD, live in your separate GitOps/deploy repo.

---

## Why two clusters, two states

- The hub's own Argo CD pods need to schedule *somewhere* — they can't be the thing that installs CNI/CCM on the spoke while depending on the spoke being ready.
- Separate `terraform apply`/state per cluster keeps blast radius small: a bad spoke change can't touch the hub, and vice versa. This also lets you add more spokes later without ever touching hub or existing spoke state.

## Structure

```
.
├── global/
│   └── network/         # Transit Gateway (shared, applied once)
├── modules/              # reusable building blocks, used by both live/hub and live/spoke
│   ├── vpc/               # + TGW-related outputs (route table ids, vpc_cidr)
│   ├── ec2/                # + trusted_api_cidr_blocks (lets hub's Argo CD reach a spoke's apiserver)
│   ├── asg/
│   ├── alb/
│   ├── k8s/                 # kubeadm bootstrap scripts: CNI + CCM always, Argo CD only if install_argocd=true
│   ├── s3/
│   ├── acm/
│   └── tgw-attachment/      # attaches a VPC to the shared TGW + adds routes to the peer CIDR
└── live/
    ├── hub/
    │   ├── envs/dev/terraform.tfvars
    │   └── *.tf              # backend key: hub/dev/terraform.tfstate
    └── spoke/
        ├── envs/dev/terraform.tfvars
        └── *.tf               # backend key: spoke/dev/terraform.tfstate
```

## Apply order (first time)

Hub and spoke each need the *other's* VPC CIDR (for TGW routing and for the hub's Argo CD to reach the spoke's apiserver). To avoid a circular `terraform_remote_state` dependency, these CIDRs are **plain tfvars you choose up front** (see `hub_vpc_cidr` / `spoke_vpc_cidrs` in each `envs/dev/terraform.tfvars`) — not looked up dynamically. Just make sure they don't overlap and match each other correctly across the two tfvars files.

```bash
# 1. Shared Transit Gateway
cd global/network
terraform init
terraform apply -var="env_prefix=dev"

# 2. Spoke (workload cluster)
cd ../../live/spoke
terraform init
terraform apply -var-file="envs/dev/terraform.tfvars"

# 3. Hub (Argo CD cluster)
cd ../hub
terraform init
terraform apply -var-file="envs/dev/terraform.tfvars"
```

Order between step 2 and 3 doesn't actually matter — both roots use static CIDRs, not each other's live outputs — but applying the TGW first is required since both roots read `global/network`'s state.

## Day-2: registering the spoke with the hub's Argo CD

This is intentionally **not** Terraform's job — it's a one-time GitOps setup step, done from your deploy repo/CI, once both clusters are up:

```bash
# from a machine with both kubeconfigs available
argocd cluster add <spoke-context> \
  --name spoke-dev \
  --kubeconfig ~/.kube/config-spoke-dev
```

This creates a `Secret` (type `argocd.argoproj.io/secret-type: cluster`) in the hub's `argocd` namespace pointing at the spoke's apiserver. From then on, `Application.spec.destination.server` in your GitOps repo can target the spoke, and the hub's Argo CD reaches it over the Transit Gateway (already allowed by `trusted_api_cidr_blocks` on the spoke's master security group).

## Adding a second spoke later

1. Copy `live/spoke` → `live/spoke-2` (or parameterize with a `terraform workspace` / new `envs/` folder if you prefer one root reused for many spokes — not done here to keep each spoke's lifecycle fully independent).
2. Give it a non-overlapping `vpc_cidr` and a new backend `key` (e.g. `spoke-2/dev/terraform.tfstate`).
3. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` list and re-apply the hub (adds the extra TGW route).
4. `argocd cluster add` it, same as above.

## What changed vs. the old single-cluster layout

| Old | New |
|---|---|
| One cluster did CNI + CCM + Argo CD + all apps | Hub: CNI + CCM + Argo CD only. Spoke: CNI + CCM only, no Argo CD |
| Argo CD host on the workload cluster's ALB | Argo CD host moved to the hub's own ALB |
| CNI installed indirectly via an external `k8s_ArgoCD` git repo's `init.sh` | CNI installed directly by the `k8s` module (`cni_manifest_url`, defaults to Calico) — Terraform no longer depends on an external app repo to make the cluster alive |
| Single VPC, single state | Two VPCs + shared Transit Gateway, two independent state files, plus a `global/network` state for the TGW |
