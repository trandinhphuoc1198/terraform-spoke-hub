# ── General ───────────────────────────────────────────────────────────────────
variable "env" {
  description = "Cluster name for this root, e.g. \"spoke-dev\""
  type        = string
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "network_state_key" {
  description = "S3 key of the global/network state for this environment"
  type        = string
  default     = "global/network/dev/terraform.tfstate"
}

variable "cluster_name" {
  type = string
}

# ── Network ───────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.1.0.0/16."
  }
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

# CIDR of the hub VPC — static, chosen up front (see live/hub's vpc_cidr).
# Used for the TGW route AND to allow the hub's Argo CD to reach this
# cluster's kube-apiserver.
variable "hub_vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.hub_vpc_cidr))
    error_message = "hub_vpc_cidr must be a valid CIDR block, e.g. 10.0.0.0/16."
  }
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

# ── ALB / Ingress ─────────────────────────────────────────────────────────────
variable "https_nodeport" {
  type    = number
  default = 30443
}

variable "apps" {
  type = map(object({
    host        = string
    health_path = string
    priority    = number
  }))
}

variable "certificate_arn" {
  type = string
}

# ── S3 ────────────────────────────────────────────────────────────────────────
variable "bucket_names" {
  type    = list(string)
  default = []
}
