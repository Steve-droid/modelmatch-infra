# Outputs the platform stack re-exports for P4 (EKS consumes vpc_id + subnet IDs) and for the
# orphan ritual (the per-AZ NAT / EIP ID lists make the post-destroy "is anything stray?" check exact).

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
  description = "IDs of the per-AZ private route tables, ordered by AZ (each default route -> its own AZ's NAT; S3 endpoint attached to all)."
  value       = aws_route_table.private[*].id
}

output "nat_gateway_ids" {
  description = "IDs of the per-AZ NAT gateways, ordered by AZ (P37). Orphan check expects az_count while up, 0 after destroy."
  value       = aws_nat_gateway.this[*].id
}

output "nat_eip_allocation_ids" {
  description = "Allocation IDs of the NAT Elastic IPs, ordered by AZ — orphan check (an unattached EIP after destroy is a cost leak)."
  value       = aws_eip.nat[*].id
}

output "nat_public_ips" {
  description = "Public IPs of the per-AZ NATs, ordered by AZ — the egress IP a pod in AZ i is seen as (P40 drill / post-3 evidence)."
  value       = aws_eip.nat[*].public_ip
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}
