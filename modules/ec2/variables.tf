variable "env" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }
variable "master_instance_type" { type = string }
variable "key_name" { type = string }
variable "alb_sg_id" { type = string }
variable "k8s_bootstrap" { type = string }
variable "cluster_name" { type = string }
variable "master_private_ip" {
  type    = string
  default = null
}

variable "ami_id" {
  description = "AMI ID for the master node — the shared Packer-built k8s base image (see /packer and modules/ami). Replaces the previous dynamic SSM AL2023 lookup."
  type        = string
}

variable "trusted_api_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to reach the kube-apiserver (port 6443) in addition
    to in-VPC traffic. Used to let the hub cluster's Argo CD reach this
    cluster's API server across the Transit Gateway. Leave empty on the hub
    itself (nothing needs to call *into* the hub's apiserver from a spoke).
  EOT
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "ARNs of S3 buckets the worker IAM role should be able to read/write. Leave empty (default) if this cluster has no S3-backed workloads — e.g. the hub."
  type        = list(string)
  default     = []
}
