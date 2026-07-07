output "vpc_id" { value = aws_vpc.main.id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "nat_instance_id" { value = aws_instance.nat.id }
output "nat_instance_public_ip" { value = aws_eip.nat.public_ip }

# Exposed so the tgw-attachment module can add routes toward the peer
# cluster's VPC without this module needing to know about Transit Gateway.
output "public_route_table_id" { value = aws_route_table.public.id }
output "private_route_table_id" { value = aws_route_table.private.id }

output "vpc_endpoints_sg_id" {
  description = "Security group ID shared by the SSM interface endpoints — exposed for debugging connectivity issues"
  value       = aws_security_group.vpc_endpoints.id
}