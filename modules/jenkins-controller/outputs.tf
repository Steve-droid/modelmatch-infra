# Surfaced to the jenkins/ root for its own outputs + for humans/scripts (webhook URL, the role to
# verify with `aws sts get-caller-identity`, the volume id for the orphan ritual).

output "public_ip" {
  description = "The EIP — the stable Jenkins UI + webhook target."
  value       = aws_eip.this.public_ip
}

output "eip_allocation_id" {
  description = "Allocation id of the EIP (for reassociation / release in the cutover ritual)."
  value       = aws_eip.this.id
}

output "instance_id" {
  description = "EC2 instance id of the controller."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group id of the controller."
  value       = aws_security_group.this.id
}

output "instance_role_arn" {
  description = "ARN of the instance role — what `aws sts get-caller-identity` shows on the box (no static keys)."
  value       = aws_iam_role.this.arn
}

output "instance_role_name" {
  description = "Name of the instance role."
  value       = aws_iam_role.this.name
}

output "jenkins_home_volume_id" {
  description = "Id of the persistent JENKINS_HOME EBS volume (track in the orphan ritual — it is prevent_destroy)."
  value       = aws_ebs_volume.jenkins_home.id
}
