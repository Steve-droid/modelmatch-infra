# The role ARN is what the calling stack annotates onto the Kubernetes ServiceAccount
# (eks.amazonaws.com/role-arn) so the SA assumes this role.

output "role_arn" {
  description = "ARN of the IRSA role (annotate on the ServiceAccount)."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IRSA role."
  value       = aws_iam_role.this.name
}
