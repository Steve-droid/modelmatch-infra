# Maps keyed by repository name. The platform stack / gitops read these (via
# terraform_remote_state on bootstrap) to reference image locations without hardcoding URLs.

output "repository_urls" {
  description = "Map of repository name -> repository URL (registry/host/path, no tag)."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repository name -> repository ARN."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
