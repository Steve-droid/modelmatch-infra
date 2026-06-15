# Inputs for our own reusable Jenkins-controller module (no third-party modules — Roey's hard rule).
# Declarations only, NO defaults: every value is supplied by the calling stack (jenkins/), never a
# module default. The module wires, by hand, the AWS pieces a registry module would hide so the
# plumbing is gradeable: a security group, an IAM instance profile, an EC2 box bootstrapped by
# user_data, a PERSISTENT EBS volume holding JENKINS_HOME, and a static EIP webhook target.

variable "name" {
  description = "Base name for the controller's resources (e.g. \"modelmatch-jenkins\" -> ...-sg, ...-role)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security group lives in (the default VPC — Jenkins is outside the platform stack's VPC so the daily platform destroy can't reach it)."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet the instance launches in (must auto-assign or be paired with the EIP for a reachable webhook target)."
  type        = string
}

variable "availability_zone" {
  description = "AZ for the persistent EBS volume — MUST equal the AZ of subnet_id (EBS is AZ-scoped)."
  type        = string
}

variable "ami_id" {
  description = "Base AMI. Designed for a clean Ubuntu 24.04 LTS base (user_data installs everything). See the jenkins/ root for the restore-AMI alternative."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the controller (t3a.medium per the umbrella cross-cutting rules)."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH admin access."
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB (OS + Docker images/build workspace; NOT JENKINS_HOME)."
  type        = number
}

variable "jenkins_home_volume_size" {
  description = "Size in GiB of the dedicated, PERSISTENT EBS volume mounted at JENKINS_HOME."
  type        = number
}

variable "jenkins_home_device" {
  description = "Requested block-device name for the JENKINS_HOME volume (e.g. /dev/sdf). On Nitro this is remapped to an NVMe device — user_data finds it via the stable by-id symlink, not this name."
  type        = string
}

variable "jenkins_home_mount" {
  description = "Filesystem path JENKINS_HOME is mounted at (Debian-package Jenkins default: /var/lib/jenkins)."
  type        = string
}

variable "admin_cidr" {
  description = "Source CIDR allowed SSH (22) + Jenkins UI (8080) — Steve's laptop /32."
  type        = string
}

variable "webhook_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach 8080 for GitHub webhook delivery (GitHub's published hook ranges)."
  type        = list(string)
}

variable "webhook_ingress_ipv6_cidrs" {
  description = "IPv6 CIDRs allowed to reach 8080 for GitHub webhook delivery (GitHub's published hook ranges)."
  type        = list(string)
}

variable "instance_role_policy_json" {
  description = "Inline permission policy (JSON) for the EC2 instance role — scoped by the caller to exact ARNs (Bedrock Nova + ECR push + the modelmatch-jenkins-* secrets). NO static AWS keys live anywhere."
  type        = string
}

variable "aws_region" {
  description = "Region for the AWS CLI default on the box (instance profile supplies creds; region is still required)."
  type        = string
}

variable "jenkins_plugins" {
  description = "Plugins user_data pre-installs into JENKINS_HOME/plugins (best-effort; UI install is the documented fallback)."
  type        = list(string)
}
