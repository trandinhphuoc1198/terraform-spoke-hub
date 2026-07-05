output "alb_dns_name" {
  description = "Public DNS of this spoke's ALB — app traffic (not Argo CD) goes here"
  value       = module.alb.alb_dns_name
}

output "master_public_ip" {
  description = "SSH here to grab the spoke kubeconfig / check bootstrap logs"
  value       = module.ec2.master_public_ip
}

output "master_private_ip" {
  value = module.ec2.master_private_ip
}

output "asg_name" {
  value = module.asg.asg_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Feed this into live/hub's spoke_vpc_cidrs list"
  value       = module.vpc.vpc_cidr
}

output "tgw_attachment_id" {
  value = module.tgw_attachment.attachment_id
}

output "cluster_name" {
  value = var.cluster_name
}