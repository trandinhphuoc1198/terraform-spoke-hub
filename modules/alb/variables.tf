variable "env"               { type = string }
variable "vpc_id"            { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "worker_sg_id"      { type = string }
variable "asg_name"          { type = string }
variable "certificate_arn"   { type = string }

variable "https_nodeport" {
  description = "NodePort the NGINX Ingress controller exposes for HTTPS"
  type        = number
  default     = 30443
}

variable "apps" {
  description = "Map of apps to deploy — each gets its own target group and ALB listener rule"
  type = map(object({
    host        = string
    health_path = string
    priority    = number
  }))
}

