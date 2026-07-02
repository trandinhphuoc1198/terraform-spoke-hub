# Module: `ec2`

Provisions the **Kubernetes master node** together with all shared IAM and security group resources that both the master and ASG workers depend on.

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
| `aws_iam_instance_profile` | `${env}-k8s-master-profile` | Binds the master IAM role to the EC2 instance |
| `aws_iam_role` | `${env}-k8s-worker-role` | IAM role for worker nodes (used by the ASG Launch Template) |
| `aws_iam_role_policy` | `${env}-k8s-worker-ebs-policy` | EBS volume management for PVCs, S3 access, SSM read for join token |
| `aws_iam_instance_profile` | `${env}-k8s-worker-profile` | Binds the worker IAM role to ASG-launched instances |
| `aws_instance` | `${env}-k8s-master` | Master EC2 instance in the first public subnet |

---

## Security group rules

### Master SG

| Direction | Source | Ports | Reason |
|---|---|---|---|
| Ingress | Worker SG | All | Workers communicate with the API server |
| Ingress | Self | All | Multi-master traffic (future expansion) |
| Ingress | `0.0.0.0/0` | TCP 22 | SSH access — restrict to your IP range in production |
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

**Cloud Controller Manager (CCM)** — EC2 describe and tag permissions so CCM can manage load balancers and routes on behalf of Kubernetes services.

**Cluster Autoscaler** — ASG describe and scale permissions so the Cluster Autoscaler (running as a pod on the master) can adjust `desired_capacity` based on pending pod pressure.

### Worker role

**EBS (for PVCs)** — Create, attach, detach, delete volumes; create snapshots; tag resources.

**S3** — `GetObject`, `PutObject`, `DeleteObject`, `ListBucket` on all buckets (`*`). Tighten to specific bucket ARNs in production.

**SSM read** — `ssm:GetParameter` scoped to the join token parameter ARN only.

---

## AMI selection

Both master and worker use the latest **Amazon Linux 2023 (AL2023) minimal** AMI resolved at apply time via the official SSM path:

```
/aws/service/ami-amazon-linux-latest/al2023-ami-minimal-kernel-default-x86_64
```

This means every `terraform apply` automatically picks up the newest patched AMI without any code changes.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `env` | `string` | Environment name — prefix for all resource names and SSM path |
| `vpc_id` | `string` | VPC ID (from `vpc` module output) |
| `private_subnet_ids` | `list(string)` | Private subnet IDs (passed through to outputs; workers use these) |
| `public_subnet_ids` | `list(string)` | Public subnet IDs — master is placed in `[0]` |
| `master_instance_type` | `string` | EC2 instance type for the master node |
| `master_private_ip` | `string` | Optional fixed private IP for the master node (e.g. `10.0.1.10`); if null, an IP is assigned automatically |
| `key_name` | `string` | EC2 SSH key pair name |
| `alb_sg_id` | `string` | ALB security group ID — used in the worker HTTPS NodePort ingress rule |
| `k8s_bootstrap` | `string` | Master `user_data` script (from `k8s` module output) |
| `cluster_name` | `string` | Kubernetes cluster name — applied as an EC2 tag for CCM discovery |

---

## Outputs

| Name | Description |
|---|---|
| `master_public_ip` | Public IP of the master — SSH entry point and where to copy kubeconfig from |
| `master_private_ip` | Private IP of the master — used by workers in `kubeadm join` |
| `worker_sg_id` | Worker security group ID — passed to the `asg` module |
| `worker_iam_instance_profile_name` | Worker instance profile name — passed to the `asg` Launch Template |
| `ssm_join_token_arn` | ARN of the join token SSM parameter — used to scope IAM policies precisely |
