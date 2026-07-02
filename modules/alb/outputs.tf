output "alb_dns_name" {
  description = "DNS name of the internet-facing ALB"
  value       = aws_lb.main.dns_name
}

output "alb_sg_id" {
  description = "Security group ID of the ALB (used to allow worker NodePort ingress)"
  value       = aws_security_group.alb.id
}
