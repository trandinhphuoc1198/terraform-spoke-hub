# ── General ───────────────────────────────────────────────────────────────────
variable "env" {
  description = "Cluster name for this root, e.g. \"hub-dev\""
  type        = string
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "cluster_name" {
  description = "K8s cluster name — must match the ASG discovery tag value"
  type        = string
}

# ── Network ───────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type = string
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

# CIDR of the spoke VPC(s) this hub needs a TGW route + apiserver access to.
# Static, chosen up front — avoids a circular remote-state dependency between
# the two roots. Add one entry per spoke as you bring more online.
variable "spoke_vpc_cidrs" {
  type    = list(string)
  default = []
}

# ── EC2 / Master ──────────────────────────────────────────────────────────────
variable "master_instance_type" {
  type = string
}

variable "key_name" {
  type = string
}

variable "master_private_ip" {
  type    = string
  default = null
}

# ── ASG / Workers ─────────────────────────────────────────────────────────────
variable "worker_instance_type" {
  type = string
}

variable "worker_min" {
  type    = number
  default = 1
}

variable "worker_max" {
  type = number
}

variable "worker_desired" {
  type = number
}

variable "worker_volume_size" {
  type    = number
  default = 20
}

# ── Kubernetes ────────────────────────────────────────────────────────────────
variable "k8s_version" {
  type    = string
  default = "1.29"
}

variable "pod_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "cni_manifest_url" {
  type    = string
  default = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
}

variable "argocd_chart_version" {
  description = "Pin the argo-cd Helm chart version for reproducible bootstraps"
  type        = string
  default     = ""
}

# ── ALB / Ingress ─────────────────────────────────────────────────────────────
variable "https_nodeport" {
  type    = number
  default = 30443
}

variable "apps" {
  description = "Apps exposed through the hub's ALB — normally just Argo CD itself"
  type = map(object({
    host        = string
    health_path = string
    priority    = number
  }))
}

variable "certificate_arn" {
  type = string
}
