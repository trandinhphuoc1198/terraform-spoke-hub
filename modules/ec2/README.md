# Module: `ec2`

Provisions the **Kubernetes master node** together with all shared IAM and security group resources that both the master and ASG workers depend on. The master has no public IP — access is via SSM Session Manager (primary) or VPC-internal SSH (fallback).

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_ssm_parameter` | `/${env}/k8s/join_token` | SecureString that holds the kubeadm join command; master writes it, workers read it |
| `aws_security_group` | `${env}-k8s-master-sg` | Master node security group |
| `aws_security_group` | `${env}-k8s-worker-sg` | Worker node security group (used by the ASG module) |
| `aws_security_group_rule` (×5) | — | Granular inbound/outbound rules for master and worker SGs |
| `aws_iam_role` | `${env}-k8s-master-role` | IAM role for the master EC2 instance |
| `aws_iam_role_policy` | `${env}-k8s-master-ssm-write-policy` | Allows master to `PutParameter` for the join token |
| `aws_iam_role_policy` | `${env}-k8s-master-ccm-policy` | EC2 permissions required by AWS Cloud Controller Manager |
| `aws_iam_role_policy` | `${env}-k8s-master-autoscaler-policy` | ASG permissions required by Cluster Autoscaler (runs on master) |
| `aws_iam_role_policy_attachment` | — | Attaches `AmazonSSMManagedInstanceCore` to the master role, unconditionally — this is the primary access path now that master has no public IP |
| `aws_iam_instance_profile` | `${env}-k8s-master-profile` | Binds the master IAM role to the EC2 instance |
| `aws_iam_role` | `${env}-k8s-worker-role` | IAM role for worker nodes (used by the ASG Launch Template) |
| `aws_iam_role_policy` | `${env}-k8s-worker-ebs-policy` | EBS volume management for PVCs, S3 access, SSM read for join token |
| `aws_iam_instance_profile` | `${env}-k8s-worker-profile` | Binds the worker IAM role to ASG-launched instances |
| `aws_instance` | `${env}-k8s-master` | Master EC2 instance in the first **private** subnet — no public IP |

---

## Accessing the master

SSM Session Manager is the primary access path (works with no public IP, no open SSH, no bastion):

```bash
aws ssm start-session --target <master_instance_id>
```

`master_instance_id` is a module output (see below), also surfaced at `live/hub` / `live/spoke` root level. This requires the three SSM interface VPC endpoints provisioned by `modules/vpc` (`ssm`, `ssmmessages`, `ec2messages`) — see that module's README.

SSH (port 22) still works as a fallback, but only from inside the VPC (`master_ingress_ssh` rule) — not from the public internet.

---

## Security group rules

### Master SG

| Direction | Source | Ports | Reason |
|---|---|---|---|
| Ingress | Worker SG | All | Workers communicate with the API server |
| Ingress | Self | All | Multi-master traffic (future expansion) |
| Ingress | VPC CIDR | TCP 22 | SSH fallback access — VPC-internal only; SSM Session Manager is the primary path |
| Egress | `0.0.0.0/0` | All | Unrestricted outbound |

### Worker SG

| Direction | Source | Ports | Reason |
|---|---|---|---|
| Ingress | Master SG | All | Master-to-worker control plane traffic |
| Ingress | Self | All | Pod-to-pod and inter-worker traffic |
| Ingress | ALB SG | TCP 30000–32767 | NodePort range for ALB health checks and forwarded traffic (includes HTTPS NodePort 30443) |
| Ingress | `10.0.0.0/16` | TCP 22 | SSH from within the VPC only |
| Egress | `0.0.0.0/0` | All | Unrestricted outbound (yum, image pulls via NAT) |

> Security group rules are managed as separate `aws_security_group_rule` resources. The `aws_security_group` resources themselves use `lifecycle { ignore_changes = [ingress, egress] }` to prevent Terraform from removing rules added by external controllers (e.g., AWS CCM).

---

## IAM permissions detail

### Master role

**SSM write** — `ssm:PutParameter` scoped to the join token parameter ARN only.

**SSM managed instance core** — `AmazonSSMManagedInstanceCore`, attached unconditionally to every master (hub and spoke). Gives Session Manager access with no public IP and no open SSH required.

**Cloud Controller Manager (CCM)** — EC2 describe and tag permissions so CCM can manage load balancers and routes on behalf of Kubernetes services.

**Cluster Autoscaler** — ASG describe and scale permissions so the Cluster Autoscaler (running as a pod on the master) can adjust `desired_capacity` based on pending pod pressure.

### Worker role

**EBS (for PVCs)** — Create, attach, detach, delete volumes; create snapshots; tag resources.

**S3** — `GetObject`, `PutObject`, `DeleteObject`, `ListBucket` on all buckets (`*`). Tighten to specific bucket ARNs in production.

**SSM read** — `ssm:GetParameter` scoped to the join token parameter ARN only.

---

## AMI selection

Both master and worker use the shared Packer-built k8s base AMI (containerd/kubeadm/kubelet/kubectl baked in) — see `/packer` and `modules/ami`. `terraform apply` automatically picks up the newest successful Packer build.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `env` | `string` | Environment name — prefix for all resource names and SSM path |
| `vpc_id` | `string` | VPC ID (from `vpc` module output) |
| `vpc_cidr` | `string` | VPC CIDR — used to scope the master/worker SSH ingress rules to VPC-internal only |
| `private_subnet_ids` | `list(string)` | Private subnet IDs — master is placed in `[0]`, workers spread across all of them |
| `master_instance_type` | `string` | EC2 instance type for the master node |
| `master_private_ip` | `string` | Optional fixed private IP for the master node — must fall within one of `private_subnet_cidrs`; if null, an IP is assigned automatically |
| `key_name` | `string` | EC2 SSH key pair name |
| `alb_sg_id` | `string` | ALB security group ID — used in the worker HTTPS NodePort ingress rule |
| `k8s_bootstrap` | `string` | Master `user_data` script (from `k8s` module output) |
| `cluster_name` | `string` | Kubernetes cluster name — applied as an EC2 tag for CCM discovery |
| `ami_id` | `string` | Shared Packer-built k8s base AMI ID (from `modules/ami`) |
| `trusted_api_cidr_blocks` | `list(string)` | CIDRs allowed to reach port 6443 in addition to in-VPC traffic (e.g. hub reaching a spoke's apiserver) |
| `s3_bucket_arns` | `list(string)` | Bucket ARNs the worker role can access |
| `register_with_hub` | `bool` | Grants the master role permission to push its own Argo CD registration secret — spokes only |
| `install_eso` | `bool` | Provisions the ESO reader IAM identity and related resources — hub only |

---

## Outputs

| Name | Description |
|---|---|
| `master_instance_id` | EC2 instance ID of the master — target for `aws ssm start-session` |
| `master_private_ip` | Private IP of the master — used by workers in `kubeadm join` |
| `master_sg_id` | Security group ID of the master |
| `worker_sg_id` | Worker security group ID — passed to the `asg` module |
| `worker_iam_instance_profile_name` | Worker instance profile name — passed to the `asg` Launch Template |
| `ssm_join_token_arn` | ARN of the join token SSM parameter — used to scope IAM policies precisely |
| `master_instance_arn` | ARN of the master instance — used to scope the CI role's `ssm:SendCommand` permission |