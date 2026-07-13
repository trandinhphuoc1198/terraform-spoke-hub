env          = "hub-dev"
region       = "ap-northeast-1"
cluster_name = "hub-dev-k8s"

# Distinct address space from every spoke — required for the TGW routing
# to work (overlapping CIDRs cannot be routed between via TGW).
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]

# Populate once the spoke VPC exists (see README bootstrap order).
# Add one entry per spoke as your fleet grows.
spoke_vpc_cidrs = ["10.1.0.0/16"]

# Smaller than the spoke — this cluster only needs to run Argo CD.
master_instance_type = "t3.small"
worker_instance_type = "c7i-flex.large"
key_name             = "key"
master_private_ip    = "10.0.11.10"

worker_min         = 1
worker_max         = 3
worker_desired     = 1
worker_volume_size = 20
master_volume_size = 20

k8s_version = "1.29"
pod_cidr    = "192.168.0.0/16"

https_nodeport  = 30443
certificate_arn = "arn:aws:acm:ap-northeast-1:633825695180:certificate/7cdd7b32-e304-4cee-989f-eb5b7cb08c34"

apps = {
  argocd = {
    host        = "argocd.phuoctd6.shop"
    health_path = "/alb-health"
    priority    = 10
  }
}
