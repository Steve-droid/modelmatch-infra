# Inputs for the persistent jenkins/ stack — declarations only, DEFAULTLESS by rule (Roey). Concrete
# NON-SECRET values are supplied explicitly via `-var-file=dev.tfvars` (we do NOT rely on auto-loaded
# terraform.tfvars / *.auto.tfvars). Secrets NEVER go in tfvars: the box's AWS access is the instance
# profile (no static keys), and pipeline creds live in Secrets Manager modelmatch-jenkins-*.

variable "aws_region" {
  description = "AWS region for all resources in this stack."
  type        = string
}

variable "name" {
  description = "Base name for the controller resources (e.g. \"modelmatch-jenkins\")."
  type        = string
}

# --- Placement (default VPC — outside the platform stack's VPC, so the daily destroy can't reach it) -
variable "vpc_id" {
  description = "VPC id for the controller's security group (the account default VPC)."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet the controller launches in (auto-assign public IP; the EIP then fixes the address)."
  type        = string
}

variable "availability_zone" {
  description = "AZ for the persistent JENKINS_HOME EBS volume — MUST equal subnet_id's AZ."
  type        = string
}

# --- Instance ---------------------------------------------------------------------
variable "ami_id" {
  description = "Base AMI. dev.tfvars uses a clean Ubuntu 24.04 LTS image (user_data installs everything — reproducible IaC + native /var/lib/jenkins). The restore AMI ami-03cfe8d7787b8eb3c is the documented alternative."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (t3a.medium per the umbrella cross-cutting rules)."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH admin."
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS size in GiB (OS + Docker images/workspace)."
  type        = number
}

variable "jenkins_home_volume_size" {
  description = "Size in GiB of the dedicated PERSISTENT EBS volume at JENKINS_HOME."
  type        = number
}

variable "jenkins_home_device" {
  description = "Requested device name for the JENKINS_HOME volume (e.g. /dev/sdf; Nitro remaps to NVMe — user_data finds it via the by-id symlink)."
  type        = string
}

variable "jenkins_home_mount" {
  description = "Mount path for JENKINS_HOME (Debian-package default: /var/lib/jenkins)."
  type        = string
}

variable "jenkins_plugins" {
  description = "Plugins user_data pre-installs (incl. the AWS Secrets Manager Credentials Provider). Best-effort; UI install is the fallback."
  type        = list(string)
}

# --- Network access ---------------------------------------------------------------
variable "admin_cidr" {
  description = "Source CIDR for SSH (22) + Jenkins UI (8080) — Steve's laptop /32."
  type        = string
}

variable "webhook_ingress_cidrs" {
  description = "GitHub's published IPv4 webhook (hook) ranges, allowed to reach 8080."
  type        = list(string)
}

variable "webhook_ingress_ipv6_cidrs" {
  description = "GitHub's published IPv6 webhook (hook) ranges, allowed to reach 8080."
  type        = list(string)
}

# --- Instance-role scope (Bedrock + Secrets Manager) ------------------------------
variable "bedrock_inference_profile_ids" {
  description = "Inference-profile IDs the e2e-live Bedrock call invokes (apac.amazon.nova-lite-v1:0, global.amazon.nova-2-lite-v1:0). Built into account-specific profile ARNs — mirrors platform IRSA role A."
  type        = list(string)
}

variable "bedrock_foundation_model_ids" {
  description = "Foundation-model IDs the profiles route to (amazon.nova-lite-v1:0, amazon.nova-2-lite-v1:0). Built into region-wildcarded, model-pinned ARNs, gated by the InferenceProfileArn condition."
  type        = list(string)
}

variable "jenkins_secret_prefix" {
  description = "FLAT, slash-free Secrets Manager prefix for pipeline credentials (modelmatch-jenkins). The instance role reads GetSecretValue on the \"<prefix>-*\" glob; the Credentials Provider plugin surfaces them as credentials whose ID = the secret name (which forbids \"/\")."
  type        = string
}
