# Outputs the platform stack re-exports for P4 (EKS consumes vpc_id + subnet IDs) and for the
# orphan ritual (the NAT / EIP IDs make the day-end "is anything stray?" check exact).

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (one per AZ), ordered by AZ. Public-facing ingress LB lands here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (one per AZ), ordered by AZ. EKS nodes / pods land here."
  value       = aws_subnet.private[*].id
}

output "public_route_table_id" {
  description = "ID of the public route table (default route -> the IGW)."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables (each default route -> the single NAT; S3 endpoint attached to all)."
  value       = aws_route_table.private[*].id
}

output "nat_gateway_id" {
  description = "ID of the single NAT gateway (the egress SPOF) — for the orphan check after destroy."
  value       = aws_nat_gateway.this.id
}

output "nat_eip_allocation_id" {
  description = "Allocation ID of the NAT's Elastic IP — orphan check (an unattached EIP after destroy is a cost leak)."
  value       = aws_eip.nat.id
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}
