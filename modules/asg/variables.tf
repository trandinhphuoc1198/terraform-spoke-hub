variable "env" { type = string }
variable "worker_instance_type" { type = string }
variable "key_name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "worker_sg_id" { type = string }
variable "worker_iam_instance_profile_name" { type = string }
variable "k8s_worker_bootstrap" { type = string }
variable "worker_min" {
  type    = number
  default = 1
}
variable "worker_max" {
  type    = number
  default = 10
}
variable "worker_desired" {
  type    = number
  default = 2
}
variable "worker_volume_size" {
  type    = number
  default = 20
}
variable "cluster_name" {
  type        = string
  description = "K8s cluster name — used in ASG discovery tags"
}
