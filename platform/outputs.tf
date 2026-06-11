# Platform-stack outputs. Re-exported from the VPC module so P4 (EKS) can consume vpc_id + subnet
# IDs, and so the day-end orphan ritual can check the NAT / EIP by ID. Also available to any future
# terraform_remote_state consumer.
output "vpc_id" {
  description = "VPC ID (P4 EKS cluster + node group)."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ingress LB)."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes / pods)."
  value       = module.vpc.private_subnet_ids
}

output "public_route_table_id" {
  description = "Public route table ID (default route -> IGW; route verification)."
  value       = module.vpc.public_route_table_id
}

output "private_route_table_ids" {
  description = "Per-AZ private route table IDs (each default route -> the single NAT; S3 endpoint attached; route verification)."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_id" {
  description = "Single NAT gateway ID (orphan check)."
  value       = module.vpc.nat_gateway_id
}

output "nat_eip_allocation_id" {
  description = "NAT Elastic IP allocation ID (orphan check)."
  value       = module.vpc.nat_eip_allocation_id
}

output "s3_vpc_endpoint_id" {
  description = "S3 gateway endpoint ID."
  value       = module.vpc.s3_vpc_endpoint_id
}
