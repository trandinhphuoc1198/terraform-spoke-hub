# Module: `vpc`

Provisions the **network foundation** for the Kubernetes cluster — a VPC with public and private subnets across two availability zones, internet egress for both tiers, and a private gateway into S3.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_vpc` | `${env}-k8s-vpc` | Main VPC with DNS support enabled |
| `aws_internet_gateway` | `${env}-igw` | Internet access for public subnets |
| `aws_subnet` (×2) | `${env}-public-subnet-{1,2}` | Subnets for the ALB and master node |
| `aws_subnet` (×2) | `${env}-private-subnet-{1,2}` | Subnets for worker nodes (no public IPs) |
| `aws_eip` | `${env}-nat-eip` | Elastic IP attached to the NAT instance |
| `aws_instance` | `${env}-nat-instance` | t3.small NAT instance providing outbound access for private subnets |
| `aws_vpc_endpoint` | `${env}-s3-endpoint` | Gateway endpoint — private/free S3 traffic |
| `aws_route_table` | `${env}-public-rt` | Routes public subnets to the IGW |
| `aws_route_table` | `${env}-private-rt` | Routes private subnets through the NAT instance and S3 endpoint |
| `aws_route_table_association` (×4) | — | Associates each subnet with its route table |

---

## Design notes

**Two-tier subnet layout**

Public subnets host resources that need direct internet reachability (ALB, master node). Private subnets host worker nodes — they have no public IPs and are unreachable from the internet inbound.

**NAT Instance**

Worker nodes are in private subnets but still need outbound internet access to pull container images and reach the Kubernetes package repositories during bootstrap. A single t3.small NAT instance (with an Elastic IP) in the first public subnet serves all private subnets.

The root module declares `wait_for_nat` as a `null_resource` with `provisioner "local-exec"` to ensure the NAT instance reports `instance-status OK` before any worker instance launches.

**S3 VPC Endpoint (Gateway type)**

Traffic between worker nodes and S3 stays within the AWS network and does not traverse the NAT instance. This reduces data transfer costs and improves throughput for workloads that read from or write to S3.

**Availability zones**

Subnets are distributed across AZs using the `aws_availability_zones` data source, so the code does not hard-code AZ names and works in any region.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `env` | `string` | Environment name — used as a name prefix for all resources |
| `vpc_cidr` | `string` | CIDR block for the VPC (e.g. `10.0.0.0/16`) |
| `public_subnet_cidrs` | `list(string)` | One CIDR per public subnet (must be within `vpc_cidr`) |
| `private_subnet_cidrs` | `list(string)` | One CIDR per private subnet (must be within `vpc_cidr`) |
| `region` | `string` | AWS region — used to construct the S3 endpoint service name |

---

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the created VPC |
| `public_subnet_ids` | List of public subnet IDs (used by ALB and master) |
| `private_subnet_ids` | List of private subnet IDs (used by ASG worker nodes) |
| `nat_instance_id` | ID of the NAT instance |
| `nat_instance_public_ip` | Public IP of the NAT instance (EIP) |
