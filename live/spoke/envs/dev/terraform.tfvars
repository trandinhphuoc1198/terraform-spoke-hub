env          = "spoke-dev"
region       = "ap-northeast-1"
cluster_name = "spoke-dev-k8s"

# Distinct address space from the hub — required for TGW routing.
vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs = ["10.1.11.0/24", "10.1.12.0/24"]

# Must match live/hub's vpc_cidr.
hub_vpc_cidr = "10.0.0.0/16"

master_instance_type = "c7i-flex.large"
worker_instance_type = "t3.small"
key_name             = "key"
master_private_ip    = "10.1.11.10"

worker_min         = 1
worker_max         = 6
worker_desired     = 1
worker_volume_size = 20
master_volume_size = 20

k8s_version = "1.29.0"
pod_cidr    = "192.168.0.0/16"

https_nodeport  = 30443
certificate_arn = "arn:aws:acm:ap-northeast-1:633825695180:certificate/7cdd7b32-e304-4cee-989f-eb5b7cb08c34"

bucket_names = [
  "tempo-s3-phuoctd6",
  "log-s3-phuoctd6"
]

# NOTE: no "argocd" entry here anymore — Argo CD's UI/API is now served
# from the hub's ALB (see live/hub/envs/dev/terraform.tfvars).
apps = {
  prometheus = {
    host        = "prometheus.phuoctd6.shop"
    health_path = "/alb-health"
    priority    = 10
  }
  fastapi = {
    host        = "fastapi.phuoctd6.shop"
    health_path = "/alb-health"
    priority    = 20
  }
  grafana = {
    host        = "grafana.phuoctd6.shop"
    health_path = "/alb-health"
    priority    = 30
  }
  hubble = {
    host        = "hubble.phuoctd6.shop"
    health_path = "/alb-health"
    priority    = 40
  }
}
