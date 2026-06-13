# Outputs the platform stack re-exports for P7 (IRSA roles bind to the OIDC issuer/ARN) and for
# kubectl/Helm wiring (cluster name/endpoint/CA).

output "cluster_name" {
  description = "EKS cluster name (aws eks update-kubeconfig --name <this>)."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Cluster API server endpoint URL."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA certificate (for a kubeconfig built without the AWS CLI helper)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version actually running on the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "The EKS-managed cluster security group ID (control-plane ↔ node traffic)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster — IRSA trust policies reference this (P7)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider — the Federated principal in every IRSA trust policy (P7)."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.this.node_group_name
}

output "node_role_arn" {
  description = "ARN of the worker node IAM role."
  value       = aws_iam_role.node.arn
}

output "ebs_csi_role_arn" {
  description = "ARN of the EBS CSI driver's IRSA role (annotated on kube-system/ebs-csi-controller-sa by the addon)."
  value       = aws_iam_role.ebs_csi.arn
}
