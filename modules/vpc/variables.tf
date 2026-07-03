variable "env" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "region" { type = string }

variable "nat_instance_type" {
  type    = string
  default = "t3.small"
}
