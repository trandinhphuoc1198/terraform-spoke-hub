# kubeadm on AWS — Hub/Spoke Kubernetes Infrastructure

A Terraform + Packer + GitHub Actions monorepo that stands up one or more
**self-managed kubeadm clusters on AWS**, wired together in a **hub/spoke**
topology over a shared Transit Gateway. The **hub** cluster runs Argo CD as
the fleet's GitOps control plane; **spoke** clusters run application
workloads and register themselves into the hub's Argo CD automatically.

If you're new to the repo, read this file top to bottom once, then use the
per-module `README.md` files (`modules/*/README.md`) as reference docs while
you work.

---

## Architecture at a glance

```
                        ┌───────────────────────────┐
                        │   global/network (TGW)     │
                        │  shared Transit Gateway     │
                        │  state: its own root/backend│
                        └──────────────┬─────────────┘
                                       │ transit_gateway_id
                          ┌────────────┴─────────────┐
                          │  (read via terraform_     │
                          │   remote_state, one-way)  │
              ┌───────────▼───────────┐   ┌───────────▼───────────┐
              │       live/hub         │   │      live/spoke        │
              │  VPC 10.0.0.0/16       │◄──┤  VPC 10.1.0.0/16       │
              │  runs: Argo CD (GitOps)│TGW│  runs: app workloads   │
              │  ALB → argocd.<domain> │   │  ALB → app.<domain>    │
              └────────────────────────┘   └────────────────────────┘
```

* **`global/network`** — a shared Transit Gateway (TGW). Applied once,
  independently, before hub or spoke. Neither hub nor spoke can
  accidentally destroy/recreate it as a side effect of their own changes.
* **`live/hub`** — one Kubernetes cluster whose only real job is to run
  **Argo CD**, the GitOps controller for the whole fleet. Its ALB serves
  the Argo CD UI/API.
* **`live/spoke`** — one Kubernetes cluster that runs actual application
  workloads (the repo ships with `prometheus`, `fastapi`, `grafana`,
  `hubble` as example apps). Additional spokes are added by copying this
  root (e.g. `live/spoke-2`) — see "Adding a second spoke" below.
* Hub and spoke VPCs are connected through the shared TGW so the hub's
  Argo CD can reach each spoke's `kube-apiserver` directly (pull-based
  GitOps against every registered cluster).

Both `live/hub` and `live/spoke` are structurally near-identical roots
(vpc → tgw-attachment → ami → k8s scripts → ec2 master → asg workers → alb),
differing mainly in a few module flags (`install_eso`, `register_with_hub`,
`trusted_api_cidr_blocks`, whether S3 buckets exist).

---

## Repo layout

```
global/network/          Shared Transit Gateway — its own state, apply first
live/hub/                Hub cluster root module (Argo CD)
live/spoke/              Spoke cluster root module (app workloads)
modules/                 Reusable Terraform modules (see table below)
packer/                  Packer + Ansible build for the shared k8s base AMI
.github/workflows/       CI (lint/validate) + CD (deploy) pipelines
.github/scripts/         Shell script templates run on cluster nodes via SSM
```

### Terraform modules

| Module | Purpose |
|---|---|
| [`vpc`](modules/vpc/README.md) | VPC, public/private subnets, NAT **instance** (not NAT Gateway — cost optimization), S3 gateway endpoint, SSM interface endpoints |
| [`ami`](modules/ami/README.md) | Looks up the newest Packer-built k8s base AMI (`purpose=k8s-base` tag) |
| [`ec2`](modules/ec2/README.md) | Master node + all shared IAM roles/security groups for master and workers |
| [`asg`](modules/asg/README.md) | Worker Launch Template + Auto Scaling Group, tagged for Cluster Autoscaler discovery |
| [`alb`](modules/alb/README.md) | Internet-facing ALB, per-app target groups, host-based HTTPS routing to the NodePort |
| [`acm`](modules/acm/README.md) | ACM certificate for the ALB's HTTPS listener, optional Route 53 auto-validation |
| [`s3`](modules/s3/README.md) | Application/cluster S3 buckets (spoke only) |
| [`tgw-attachment`](modules/tgw-attachment) | Attaches a cluster's VPC to the shared TGW and adds peer routes |
| [`k8s`](modules/k8s/README.md) | Renders `master_userdata` / `worker_userdata` bootstrap scripts (content only — doesn't attach or run anything) |

---

## What's baked into the AMI vs. what runs at bootstrap time

Node bring-up is split across three layers, and understanding *why* helps
when something breaks:

| Layer | What it does | When it runs | Where it lives |
|---|---|---|---|
| **Packer + Ansible** (`/packer`) | swap off, kernel modules, sysctl, containerd, kubeadm/kubelet/kubectl install | Once, ahead of time, produces an AMI | `packer/ansible/playbook.yml` |
| **`user_data` / CI script** | `kubeadm init` or `kubeadm join`, CNI (Cilium), AWS CCM | At node launch / cluster bootstrap | `modules/k8s/templates/*.tpl` |
| **Argo CD (GitOps)** | Everything else: CCM upgrades, External Secrets Operator, application workloads | Continuously, reconciling from Git | separate `gitops` repo (referenced by raw URL) |

This used to all be dynamic `user_data` (installing containerd/kubeadm on
every boot) and later grew to include imperative Argo CD/CCM/ESO installs
directly in Terraform. Both were refactored out:

* **AMI baking** (Packer/Ansible) removes repeated package installs from
  every boot — faster, more reliable launches, and worker scale-out via
  Cluster Autoscaler no longer depends on package mirrors being reachable
  at exactly the right moment.
* **Moving `kubeadm init` out of master `user_data` and into a CI job**
  (`k8s-cluster-bootstrap.yml`, driven over SSM `send-command`) means a
  failed bootstrap shows up as a **failed GitHub Actions job with logs**,
  instead of failing silently inside `cloud-init` on a box nobody is
  watching.
* Workers still run `kubeadm join` from `user_data` at launch time — ASG
  scale-out (driven by Cluster Autoscaler) has no CI trigger to hook into,
  so it has to stay boot-time and poll SSM for the join token
  (`modules/k8s/templates/worker_init.sh.tpl`).
* **Argo CD/CCM upgrades/ESO** moved out of Terraform and CI scripts
  entirely and into the cluster's own Argo CD reconciliation loop, because
  Terraform has no diff/rollback story for imperative install steps, and
  ordinary Kubernetes resources belong in a GitOps loop, not a shell
  script embedded in a `.tf` file.

One exception: AWS CCM is still installed imperatively inside
`master_init.sh.tpl`, unconditionally, on every cluster — every node
carries the `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`
taint from `cloud-provider=external` until CCM clears it, and that has to
happen before anything (including Argo CD's own pods) can schedule.

---

## Access model

Master nodes have **no public IP**. The primary access path is
**AWS SSM Session Manager**:

```bash
aws ssm start-session --target <master_instance_id>
```

`master_instance_id` is a Terraform output on both `live/hub` and
`live/spoke`. This works because:
* the master's IAM role has `AmazonSSMManagedInstanceCore` attached
  unconditionally, and
* `modules/vpc` provisions the three SSM interface VPC endpoints
  (`ssm`, `ssmmessages`, `ec2messages`) required for the agent to reach
  Session Manager without a route to the public internet.

SSH (port 22) still works as a fallback, but only from inside the VPC — it
is not reachable from the internet.

---

## How a spoke joins the hub's Argo CD (GitOps registration)

This is the trickiest cross-cutting flow in the repo, so it's worth
tracing end to end:

1. **Terraform (`live/spoke`)** provisions the spoke cluster; the master's
   IAM role is granted permission to write only to
   `argocd-clusters/<cluster_name>` in Secrets Manager
   (`register_with_hub = true`).
2. **CI (`k8s-register-with-hub.yml`)** runs
   `register-with-hub.sh.tpl` on the spoke master over SSM: it creates an
   `argocd-manager` service account with `cluster-admin`, mints a token,
   and pushes `{name, server, token, caData}` to Secrets Manager. It also
   installs a systemd timer that re-pushes a fresh token every 30 days
   (tokens are not stored in Terraform state).
3. **On the hub**, External Secrets Operator (installed by Argo CD's own
   `ApplicationSet`, seeded initially with `bootstrap-eso-secret.sh.tpl`'s
   `aws-creds` Secret) reads that same Secrets Manager path and
   materializes a Kubernetes `Secret` labeled
   `argocd.argoproj.io/secret-type=cluster`.
4. Argo CD sees the labeled Secret and treats the spoke as a registered
   cluster — no `argocd cluster add` step, no CI step that mutates the
   hub on every spoke deploy.
5. **CI (`argocd-register-spoke.yml`)** polls the hub (again via SSM) for
   that Secret to confirm the pipeline actually completed, and fails
   loudly with a checklist of likely causes if it times out instead of
   assuming ESO will "get there eventually."

Registering a cluster with Argo CD itself is a **GitOps fact**, not a CI
action: it happens by adding `argocd/clusters/<name>.yaml` to the separate
`gitops` repo once.

---

## Networking notes

* **NAT instance, not NAT Gateway.** A single `t3.small` EC2 instance
  (`modules/vpc`) provides outbound internet access for both private
  subnets — cheaper than a managed NAT Gateway for a learning/small-fleet
  setup. `live/hub` and `live/spoke` both run a `null_resource` with a
  `local-exec` provisioner that waits for `instance-status-ok` on the NAT
  instance before any worker (or the master) launches, so nodes don't race
  a NAT that isn't routing traffic yet.
* **S3 traffic bypasses the NAT instance** via a Gateway VPC endpoint.
* **CIDR overlap guard.** Both `live/hub/main.tf` and `live/spoke/main.tf`
  define a Terraform `check` block that converts every relevant CIDR to a
  numeric range and asserts none overlap — this catches a copy-pasted
  `vpc_cidr` at `terraform plan` time instead of deep inside a failed TGW
  route `apply`.
* **ALB → NodePort.** The ALB never talks to Kubernetes directly; it
  forwards HTTPS to a fixed NodePort (`30443`) on worker nodes, and NGINX
  Ingress (deployed via Argo CD) does host-header routing inside the
  cluster from there. One ALB target group + listener rule is created per
  entry in the `apps` variable.

---

## Apply order (first-time bring-up)

```
1. global/network   (shared TGW — must exist before hub or spoke)
2. live/hub         (terraform apply → kubeadm bootstrap → Argo CD install)
3. live/spoke       (terraform apply → kubeadm bootstrap → register with hub → verify)
```

Use **`deploy-all.yml`** (GitHub Actions, manual trigger) to run all three
in order for a brand-new environment. For any day-2 change to a single
cluster, use the narrower workflow instead — it won't force an unrelated
cluster's bootstrap/Argo CD steps to re-run:

| Workflow | Scope |
|---|---|
| `deploy-network.yml` | `global/network` only — rare, e.g. changing `amazon_side_asn` |
| `deploy-hub.yml` | `live/hub` terraform apply → kubeadm/CNI → Argo CD install |
| `deploy-spoke.yml` | `live/spoke` (or any `spoke_dir`) terraform apply → kubeadm/CNI → register with hub → verify Argo CD registration |
| `deploy-all.yml` | Chains all three — **first-time bring-up only** |
| `packer-build-ami.yml` | Manual only — builds a new base AMI (never runs on push/PR) |

### Adding a second spoke later

`deploy-spoke.yml` and `k8s-register-with-hub.yml` both take a
`spoke_dir` / `working_directory` input (default `live/spoke`), so a
second spoke doesn't require new workflow jobs:

1. Copy `live/spoke` → `live/spoke-2` (new backend key, new `vpc_cidr`
   disjoint from every other cluster, new `envs/<env>/terraform.tfvars`).
2. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` and re-apply the hub
   (needed for the TGW route + apiserver trust — see `trusted_api_cidr_blocks`).
3. Run `deploy-spoke.yml` with `spoke_dir: live/spoke-2`.

---

## State & backend

All roots use an **S3 backend** with **S3 native locking**
(`use_lockfile = true` — no DynamoDB table required), bucket
`terraform-state-phuoctd6`, region `ap-northeast-1`. Each root's `key` is
supplied at `terraform init` time via `-backend-config=envs/<env>/backend.hcl`
so `backend.tf` itself stays identical across environments:

| Root | State key |
|---|---|
| `global/network` | `global/network/<env>/terraform.tfstate` |
| `live/hub` | `hub/<env>/terraform.tfstate` |
| `live/spoke` | `spoke/<env>/terraform.tfstate` |

`live/hub` and `live/spoke` each read `global/network`'s state via
`terraform_remote_state` (one-directional — network has no dependency
back on hub/spoke, so it's safe to apply hub/spoke any time after network
has been applied once).

---

## CI checks (`terraform.yml`, on every PR touching `.tf`/`.tfvars`/Packer files)

* `terraform fmt -check`
* `terraform validate` (matrix: `global/network`, `live/hub`, `live/spoke`; `init -backend=false`, no real credentials needed)
* `tflint` (matrix, same three roots — see `.tflint.hcl` for enabled rules)
* `packer validate` + `packer fmt -check` + `ansible-lint` (static only — CI has no AWS credentials, so it cannot actually launch a build instance)
* `trivy` config scan across the whole repo

---

## Security notes worth knowing

* Master/worker security groups use
  `lifecycle { ignore_changes = [ingress, egress] }` so Terraform doesn't
  fight AWS Cloud Controller Manager, which adds its own SG rules for
  LoadBalancer-type Services at runtime.
* The worker IAM role's S3 policy (`modules/ec2`) is scoped to
  `s3_bucket_arns` when non-empty, otherwise omitted entirely — the hub
  passes none (it has no S3-backed workloads).
* The join-token SSM parameter (`/​<env>/k8s/join_token`) is a
  `SecureString`; Terraform is told to ignore its `value` — the master
  writes the real token at bootstrap time, and Terraform must not
  overwrite it back to the placeholder on a later `apply`.
* `.tflint.hcl` deliberately disables `terraform_module_pinned_source` —
  every module source is a local path in this monorepo, so version
  pinning doesn't apply the way it would for a remote/registry source.

---

## Where to look next

* Each module has its own `README.md` with resource tables, variable
  references, and design rationale — read the module's README before
  changing its `main.tf`.
* `packer/README.md` explains exactly what's baked into the AMI vs. what
  stays dynamic, and the rollout implications of a new AMI build (workers
  roll via `instance_refresh`; the master is a single instance and needs a
  manual replace).
* `modules/k8s/README.md` has the full table of "who owns what" for
  cluster bring-up (kubeadm vs. CI vs. Argo CD) — the single best
  reference if you're debugging why something didn't get installed.