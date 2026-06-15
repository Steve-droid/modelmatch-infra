# Cross-stack / human-facing outputs for the jenkins/ stack: the webhook URL to register on GitHub,
# the instance role to verify with `aws sts get-caller-identity` on the box, and the ids the cutover
# + orphan rituals need.

output "jenkins_public_ip" {
  description = "EIP — the stable Jenkins UI + webhook target."
  value       = module.jenkins.public_ip
}

output "jenkins_url" {
  description = "Jenkins UI / webhook base URL (plain HTTP :8080 + HMAC, per the locked webhook decision)."
  value       = "http://${module.jenkins.public_ip}:8080"
}

output "jenkins_webhook_url" {
  description = "GitHub webhook endpoint to register on the FE/BE/gitops/proof repos."
  value       = "http://${module.jenkins.public_ip}:8080/github-webhook/"
}

output "jenkins_eip_allocation_id" {
  description = "EIP allocation id (for reassociation / release in the cutover ritual)."
  value       = module.jenkins.eip_allocation_id
}

output "jenkins_instance_id" {
  description = "Controller EC2 instance id."
  value       = module.jenkins.instance_id
}

output "jenkins_instance_role_arn" {
  description = "Instance role ARN — what `aws sts get-caller-identity` shows on the box (no static keys)."
  value       = module.jenkins.instance_role_arn
}

output "jenkins_security_group_id" {
  description = "Controller security group id."
  value       = module.jenkins.security_group_id
}

output "jenkins_home_volume_id" {
  description = "Persistent JENKINS_HOME EBS volume id (prevent_destroy; track in the orphan ritual)."
  value       = module.jenkins.jenkins_home_volume_id
}
