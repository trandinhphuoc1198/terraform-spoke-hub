# AWS Self-Managed Kubernetes — Hub & Spoke Terraform

Two independent `kubeadm` clusters on EC2, connected over a Transit Gateway:

- **hub** — small cluster whose only job is running Argo CD.
- **spoke** — your actual workload cluster (what the old single-cluster setup used to be). Managed remotely by the hub's Argo CD; runs no Argo CD itself.

Terraform's job stops at **"instance exists, is joinable, reachable via SSM."** It does not bring the cluster to Ready, and it does not install anything on top of Kubernetes. Bringing kubeadm up (CNI included) is a one-time CI step run via SSM send-command; everything that's an ordinary Kubernetes resource — AWS Cloud Controller Manager, External Secrets Operator, Argo CD itself (bootstrap only), and every application — is installed either by a CI bootstrap step (only where nothing else could possibly do it yet) or by Argo CD reconciling from Git. See "Apply order" below for the full sequence.

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
│   ├── k8s/                 # kubeadm init + CNI script only — see modules/k8s/README.md
│   ├── s3/
│   ├── acm/
│   └── tgw-attachment/      # attaches a VPC to the shared TGW + adds routes to the peer CIDR
├── .github/
│   ├── templates/
│   │   └── argocd-cluster-external-secret.yaml.tpl   # labeled cluster Secret (cluster-role, cluster-env)
│   ├── scripts/              # bootstrap scripts run via SSM send-command, NOT terraform user_data
│   │   ├── bootstrap-argocd.sh.tpl
│   │   ├── bootstrap-eso-secret.sh.tpl
│   │   └── register-with-hub.sh.tpl
│   └── workflows/
│       ├── deploy-infra.yml            # orchestrates everything below, in order
│       ├── k8s-cluster-bootstrap.yml   # kubeadm init + CNI, hub or spoke
│       ├── k8s-bootstrap-argocd.yml    # hub only, one-time Argo CD install
│       ├── k8s-register-with-hub.yml   # spoke only, token push + rotation timer
│       ├── argocd-register-spoke.yml   # registers spoke as a labeled cluster Secret in hub's argocd ns
│       ├── packer-build-ami.yml
│       └── terraform.yml               # fmt/validate/tflint/security-scan CI
└── live/
    ├── hub/
    │   ├── envs/dev/terraform.tfvars
    │   └── *.tf              # backend key: hub/dev/terraform.tfstate
    └── spoke/
        ├── envs/dev/terraform.tfvars
        └── *.tf               # backend key: spoke/dev/terraform.tfstate
```

## Apply order (first time)

Hub and spoke each need the *other's* VPC CIDR (for TGW routing and for the hub's Argo CD to reach the spoke's apiserver). To avoid a circular `terraform_remote_state` dependency, these CIDRs are **plain tfvars you choose up front** (see `hub_vpc_cidr` / `spoke_vpc_cidrs` in each `envs/dev/terraform.tfvars`) — not looked up dynamically. Just make sure they don't overlap and match each other correctly across the two tfvars files. (A `check` block in each root's `main.tf` verifies this automatically at `plan`/`apply` time — see "CIDR overlap detection" below.)

Every root's `key` is passed at `init` time, not hardcoded in `backend.tf`, so the same `.tf` files work for every environment:

```bash
# 1. Shared Transit Gateway
cd global/network
terraform init -backend-config="envs/dev/backend.hcl"
terraform apply -var="env_prefix=dev"

# 2. Spoke (workload cluster) — infra only; node won't be Ready yet
cd ../../live/spoke
terraform init -backend-config="envs/dev/backend.hcl"
terraform apply -var-file="envs/dev/terraform.tfvars"

# 3. Hub (Argo CD cluster) — infra only; node won't be Ready yet
cd ../hub
terraform init -backend-config="envs/dev/backend.hcl"
terraform apply -var-file="envs/dev/terraform.tfvars"
```

Order between step 2 and 3 doesn't actually matter — both roots use static CIDRs, not each other's live outputs — but applying the TGW first is required since both roots read `global/network`'s state (via `network_state_key`, itself a tfvar so it can point at a different `global/network` env if you ever split that too).

**Terraform finishes here with instances running but clusters not yet Ready.** Bringing a cluster up the rest of the way is CI's job, not Terraform's — every step below runs via SSM send-command against the private master (no public IP, no direct network path from a runner), and each failure surfaces as a failed CI job with logs attached, rather than hiding in a `user_data`/cloud-init log on a box nobody's watching:

1. **`k8s-cluster-bootstrap.yml`** (hub) — kubeadm init + CNI apply. Hub master reaches `Ready`.
2. **`k8s-cluster-bootstrap.yml`** (spoke) — same, for the spoke master.
3. **`k8s-bootstrap-argocd.yml`** — hub only, one-time. Installs Argo CD via Helm (the one unavoidable imperative step — Argo CD can't install itself), waits for its CRDs, then applies exactly three manifests from the gitops repo (`platform-infra` and `platform-apps` `AppProject`s, plus `root-app`). Also seeds the `aws-creds` Secret External Secrets Operator needs to reach AWS Secrets Manager (can't come from ESO itself, since ESO needs it to function). **Everything Kubernetes-native from this point forward — AWS CCM, ESO, all apps — is installed by Argo CD from Git, not by Terraform or by any script in this repo.**
4. **`k8s-register-with-hub.yml`** — spoke only. Creates the `argocd-manager` service account/token on the spoke, pushes the initial registration payload to Secrets Manager, and installs a host-level systemd timer that rotates the token every 30 days (kept on the host rather than as a Kubernetes `CronJob` — see "Known, intentional trade-offs" below).
5. **`argocd-register-spoke.yml`** — reads that Secrets Manager payload and creates the corresponding cluster `Secret` in the hub's `argocd` namespace, labeled `cluster-role=workload` and `cluster-env=<env>`. This label is what lets the gitops repo's `ApplicationSet`s target "every workload cluster" instead of hardcoding cluster names — see "Cluster targeting" below.

`deploy-infra.yml` runs all five steps automatically, in this order, on `workflow_dispatch`. Any step is also independently re-runnable via its own `workflow_dispatch` — useful after manually replacing the master instance, since the master is a single `aws_instance`, not in an ASG (no automatic rolling replacement).

## Cluster targeting (Argo CD `ApplicationSet`s, gitops repo)

Every cluster Argo CD knows about — including the hub's own "local" cluster, labeled by `k8s-bootstrap-argocd.yml` alongside the Argo CD install itself — carries `cluster-role` and `cluster-env` labels on its registration Secret. `ApplicationSet`s in the gitops repo select clusters by label instead of hardcoding server URLs, so:

- An `ApplicationSet` with `generators: [{clusters: {}}]` (no selector) targets every registered cluster — e.g. AWS CCM, which every cluster needs regardless of whether it also runs Argo CD.
- An `ApplicationSet` with `generators: [{clusters: {selector: {matchLabels: {cluster-role: workload}}}}]` targets only workload clusters — e.g. Prometheus, Grafana, application charts.

Adding a second spoke later means registering it with `cluster-role: workload` the same way the first one was — it automatically picks up every workload-scoped `ApplicationSet` in the gitops repo with zero changes there.

## Day-2: registering the spoke with the hub's Argo CD

Handled automatically by `argocd-register-spoke.yml` (step 5 above) as part of `deploy-infra.yml`. Manually, from a machine with the AWS OIDC role available:

```bash
gh workflow run argocd-register-spoke.yml \
  -f spoke_cluster_name=spoke-dev-k8s \
  -f hub_env=hub-dev \
  -f cluster_role=workload \
  -f cluster_env=dev
```

This creates the labeled `Secret` (type `argocd.argoproj.io/secret-type: cluster`) in the hub's `argocd` namespace pointing at the spoke's apiserver, reachable over the Transit Gateway (already allowed by `trusted_api_cidr_blocks` on the spoke's master security group).

## Adding a second spoke later

1. Copy `live/spoke` → `live/spoke-2` (or parameterize with a `terraform workspace` / new `envs/` folder if you prefer one root reused for many spokes — not done here to keep each spoke's lifecycle fully independent).
2. Give it a non-overlapping `vpc_cidr` and a new backend `key` (e.g. `spoke-2/dev/terraform.tfstate`).
3. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` list and re-apply the hub (adds the extra TGW route).
4. Run `k8s-cluster-bootstrap.yml`, `k8s-register-with-hub.yml`, and `argocd-register-spoke.yml` against it (same steps 2/4/5 above) — no changes needed to `k8s-bootstrap-argocd.yml`, since Argo CD itself only installs once, on the hub.
5. Label it `cluster-role: workload` at registration time and it picks up every workload-scoped `ApplicationSet` automatically — no gitops repo changes.

## What changed vs. the old single-cluster layout

| Old | New |
|---|---|
| One cluster did CNI + CCM + Argo CD + all apps | Hub: CNI + CCM + Argo CD only. Spoke: CNI + CCM only, no Argo CD |
| Argo CD host on the workload cluster's ALB | Argo CD host moved to the hub's own ALB |
| CNI installed indirectly via an external `k8s_ArgoCD` git repo's `init.sh` | CNI installed directly by the `k8s` module (`cni_manifest_url`, defaults to Calico) — Terraform no longer depends on an external app repo to make the cluster alive |
| Single VPC, single state | Two VPCs + shared Transit Gateway, two independent state files, plus a `global/network` state for the TGW |
| kubeadm init, CCM, Argo CD, and ESO all ran inside `user_data` at instance launch, with no visibility into failures | Terraform only bakes/launches the node. kubeadm init + CNI, Argo CD install, and hub registration each run as a separate CI job via SSM send-command — a failed step fails a CI job with logs, not a silent cloud-init failure |
| CCM install was nested inside the same conditional as Argo CD, so spoke clusters never actually got CCM | CCM is an Argo CD `ApplicationSet` targeting every registered cluster (label-based, no conditional coupling to Argo CD's own presence) |
| CNI apply was also nested inside the Argo-CD-only conditional, so spoke clusters never actually got CNI either | CNI apply runs unconditionally in the trimmed `master_init.sh.tpl`, for every cluster |
| Apps deployed to whichever cluster the gitops repo happened to hardcode | Clusters are registered with `cluster-role`/`cluster-env` labels; `ApplicationSet`s in the gitops repo select clusters by label, so which cluster gets which app is controlled centrally instead of per-manifest |

## Best-practices fixes applied

- **Partial backend config** — `backend.tf` no longer hardcodes `key`; it's passed via `-backend-config="envs/<env>/backend.hcl"` at `init` time. Same `.tf` files now work across `dev`/`prod`/any future env without editing code.
- **CIDR validation** — every CIDR variable validates its format (`can(cidrnetmask(...))`), and a `check` block in each root does real numeric-range overlap detection between `vpc_cidr`/`hub_vpc_cidr`/`spoke_vpc_cidrs`, catching a copy-pasted duplicate CIDR at `plan` time instead of a failed TGW route deep in `apply`.
- **IAM least privilege** — the CCM policy's mutating actions (`CreateTags`, `AuthorizeSecurityGroupIngress`, etc.) are now conditioned on `aws:ResourceTag/kubernetes.io/cluster/<name> = owned`, so this role can't touch another cluster's security groups even if one exists in the same account. Worker S3 access is scoped to the actual bucket ARNs (`module.s3.bucket_arns`) instead of `Resource: "*"`. Note: `ec2:Describe*` actions are still `Resource: "*"` — that's an AWS IAM limitation (these actions don't support resource-level permissions at all), not something left un-scoped by choice.
- **Provisioner hardening** — the `local-exec` NAT-readiness wait now has `on_failure = continue` and documents exactly why it exists (Terraform has no native "wait for EC2 status check" resource) so a missing AWS CLI/permission on the runner degrades gracefully instead of blocking the whole apply.
- **Terraform scope discipline** — Terraform stops at "node exists, is joinable, reachable via SSM." kubeadm init/CNI, Argo CD's install, and hub cluster registration all moved out of `templatefile()`-generated `user_data` into CI workflows invoked via SSM send-command, so each step gets real pass/fail signal and logs instead of being invisible to both Terraform state and Terraform's exit code. See `modules/k8s/README.md` for the full breakdown of what lives where.
- **CI** — `.github/workflows/terraform.yml` runs `terraform fmt -check`, `terraform validate`, `tflint`, and `tfsec` against every root on each PR.

## Known, intentional trade-offs (not fixed — by design)

- **Local-path module sources** (`source = "../../modules/vpc"`) rather than a versioned Git/registry reference. Correct for a single monorepo where hub, spoke, and modules all change together in one PR. If modules ever move to their own repo consumed by multiple independent repos, switch to `source = "git::https://github.com/<org>/terraform-modules.git//vpc?ref=v1.2.0"` so consumers can upgrade on their own schedule.
- **`ec2:Describe*` stays `Resource: "*"`** in the CCM policy — see IAM note above, this is an AWS API limitation, not a Terraform gap.
- **Argo CD's own install stays imperative** (`k8s-bootstrap-argocd.yml`, via SSM). Everything Argo CD can install, it does — this is the one unavoidable exception, since Argo CD has to exist before it can reconcile anything, including itself. Re-running this workflow is safe (`helm upgrade --install` is idempotent) if the chart needs upgrading.
- **`register_with_hub`'s rotation timer stays on the host as a systemd timer**, not a Kubernetes `CronJob`, because neither `modules/ec2` nor `modules/asg` currently sets an IMDS hop-limit that would isolate pod-level access to the instance role's credentials. A `CronJob` on an unrestricted node could let any workload scheduled there reach the same credentials. Revisit once IMDS hop-limits are locked down.
- **Worker `user_data` still self-bootstraps at launch** (`kubeadm join`, via `modules/asg`) rather than going through the same CI/SSM path as the master. ASG scale-out is an autoscaler-driven event with no CI trigger to hook into, so this one has to stay boot-time.

## Limitations
1. aws-node-termination-handler
2. Offload Logging to AWS CloudWatch Agent
3. multi master node
4. No automated rollback if `k8s-bootstrap-argocd.yml` partially succeeds (e.g. Argo CD installs but a gitops bootstrap manifest fails to apply) — recovering currently means re-running the workflow (idempotent) or manually inspecting via SSM.