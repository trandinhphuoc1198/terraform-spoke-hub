# Module: `k8s`

Renders the two bootstrap scripts used to bring a kubeadm cluster's nodes up — `master_userdata` and `worker_userdata`. This module produces **script content only**; it does not run anything or attach `user_data` to any instance itself.

---

## Scope (deliberately narrow)

This module's only job is "get kubeadm to a Ready node with CNI installed." It does **not** install AWS Cloud Controller Manager, Argo CD, or External Secrets Operator, and does not handle hub cluster registration. Those moved to CI workflows and, past Argo CD's own install, to Argo CD itself:

| Concern | Where it lives now |
|---|---|
| kubeadm init/join, CNI | This module's templates, run via `.github/workflows/k8s-cluster-bootstrap.yml` (SSM send-command) — the only piece still consumed as `worker_userdata` set directly as ASG `user_data`, since worker scale-out has no CI trigger to hook into |
| AWS Cloud Controller Manager | Argo CD `ApplicationSet` in the gitops repo, targeting every registered cluster |
| Argo CD itself | `.github/workflows/k8s-bootstrap-argocd.yml`, hub only, one-time (chicken-and-egg: Argo CD can't install itself) |
| External Secrets Operator | Argo CD `ApplicationSet` in the gitops repo (chart), plus a `ClusterSecretStore` CR at a later `sync-wave` |
| `aws-creds` Secret for ESO | `.github/workflows/k8s-bootstrap-argocd.yml` — can't come from ESO itself, since ESO needs it to function |
| Hub cluster registration (token push + rotation) | `.github/workflows/k8s-register-with-hub.yml` (spoke only) |

Why: Terraform can't track state for imperative install steps (no diff, no rollback), and anything that's an ordinary Kubernetes resource belongs in Argo CD's reconciliation loop, not a shell script embedded in a Terraform template. See the root README's "What changed" table for the fuller rationale.

---

## Outputs

| Name | Description |
|---|---|
| `master_userdata` | kubeadm init + CNI script content. **Not** attached as `user_data` — consumed by `k8s-cluster-bootstrap.yml` via `terraform output -raw master_userdata`, pushed to the instance over SSM send-command. |
| `worker_userdata` | kubeadm join script content. Attached directly as the ASG launch template's `user_data` (`modules/asg`) — this one stays boot-time, since new workers bootstrap unattended on scale-out. |

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `k8s_version` | `string` | — | Kubernetes minor version (e.g. `1.29`) |
| `pod_cidr` | `string` | — | Pod network CIDR passed to `kubeadm --pod-network-cidr` |
| `env` | `string` | — | Target environment/cluster name (e.g. `hub-dev`, `spoke-dev`) |
| `cni_manifest_url` | `string` | Calico v3.28.0 manifest | Manifest URL applied right after `kubeadm init` |