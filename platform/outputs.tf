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

# --- EKS (P4) — re-exported for P7 (IRSA binds to the OIDC issuer/ARN) + kubectl/Helm wiring ---

output "cluster_name" {
  description = "EKS cluster name (aws eks update-kubeconfig --name <this>)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Cluster API server endpoint URL."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA certificate."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group ID (control-plane ↔ node traffic; later slices may reference it)."
  value       = module.eks.cluster_security_group_id
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer URL (P7 IRSA trust)."
  value       = module.eks.oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (P7 IRSA trust)."
  value       = module.eks.oidc_provider_arn
}

output "node_group_name" {
  description = "Managed node group name."
  value       = module.eks.node_group_name
}

output "node_role_arn" {
  description = "Worker node IAM role ARN."
  value       = module.eks.node_role_arn
}

output "ebs_csi_role_arn" {
  description = "EBS CSI driver IRSA role ARN."
  value       = module.eks.ebs_csi_role_arn
}

# --- IRSA (P7) — role ARNs for chart annotations (P14 backend SA / P12 ESO SecretStore) ---

output "irsa_backend_role_arn" {
  description = "Role A ARN — annotate on the backend SA (app/modelmatch-backend) in P14; grants Bedrock Nova InvokeModel + ingestion S3 GetObject/PutObject."
  value       = module.irsa_backend.role_arn
}

output "irsa_eso_role_arn" {
  description = "Role B ARN — used by the ESO SecretStore (external-secrets/external-secrets) in P12; grants secretsmanager:GetSecretValue on the app secret path."
  value       = module.irsa_eso.role_arn
}

# --- ArgoCD (P10) — verification / access helpers (no secrets emitted) ---

output "cluster_namespaces" {
  description = "The 4 cluster namespaces Terraform created (argocd/app/monitoring/logging)."
  value       = sort([for ns in kubernetes_namespace.this : ns.metadata[0].name])
}

output "argocd_namespace" {
  description = "Namespace ArgoCD is installed in."
  value       = helm_release.argocd.namespace
}

output "argocd_version" {
  description = "Installed argo-cd chart version (app version is the chart's appVersion)."
  value       = helm_release.argocd.version
}

output "argocd_admin_password_cmd" {
  description = "How to retrieve the initial ArgoCD admin password (the secret itself is never output)."
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_cmd" {
  description = "Port-forward to the ArgoCD UI for the P10 demo (HTTPS ingress is P15). Then open https://localhost:8080 (user: admin)."
  value       = "kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:443"
}
