output "argocd_url" {
  description = "Public DNS of the hub ALB — point argocd.<domain> here"
  value       = module.alb.alb_dns_name
}

output "master_public_ip" {
  description = "SSH here to grab the hub kubeconfig / check bootstrap logs"
  value       = module.ec2.master_public_ip
}

output "master_private_ip" {
  value = module.ec2.master_private_ip
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Feed this into live/spoke's hub_vpc_cidr variable"
  value       = module.vpc.vpc_cidr
}

output "master_sg_id" {
  value = module.ec2.master_sg_id
}

output "tgw_attachment_id" {
  value = module.tgw_attachment.attachment_id
}
