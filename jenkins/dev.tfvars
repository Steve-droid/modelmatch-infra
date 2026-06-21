# Concrete NON-SECRET values for the persistent jenkins/ stack (the graded CI controller).
# Passed EXPLICITLY: `terraform -chdir=jenkins plan|apply -var-file=dev.tfvars`
# (we do NOT rely on auto-loaded terraform.tfvars / *.auto.tfvars — Roey's rule, predictability).
# Committed on purpose: nothing here is a secret. The box's AWS access is the instance profile (no
# static keys); pipeline creds live in Secrets Manager modelmatch-jenkins-*.

aws_region = "ap-south-1"
name       = "modelmatch-jenkins"

# --- Placement: the account DEFAULT VPC (outside platform/'s VPC, so the daily destroy can't reach
#     Jenkins). Public subnet in ap-south-1a (auto-assign public IP); EBS pinned to the same AZ. ---
vpc_id            = "vpc-0bd81767011353364"    # default VPC (ap-south-1)
subnet_id         = "subnet-0cf034b849dfe48f9" # default-VPC public subnet, ap-south-1a
availability_zone = "ap-south-1a"

# --- Instance ---
# Clean Ubuntu 24.04 LTS amd64 (Canonical SSM current, ap-south-1, 2026-06-15) — reproducible IaC,
# user_data installs everything, native JENKINS_HOME at /var/lib/jenkins. The restore AMI from the
# smoke (ami-03cfe8d7787b8eb3c, docker-compose Jenkins) is the documented alternative; it is also
# preserved as a backup before this stack's first apply (see the runbook).
ami_id        = "ami-006f82a1d5a27da54"
instance_type = "t3a.medium"
key_name      = "develeap-key" # ed25519 keypair already in the account

root_volume_size         = 30 # OS + Docker images/build workspace
jenkins_home_volume_size = 20 # dedicated persistent JENKINS_HOME
jenkins_home_device      = "/dev/sdf"
jenkins_home_mount       = "/var/lib/jenkins"

jenkins_plugins = [
  "aws-secrets-manager-credentials-provider", # surfaces modelmatch-jenkins-* as Jenkins credentials
  "github",                                   # GitHub webhook + integration
  "git",
  "workflow-aggregator", # pipeline
  "configuration-as-code",
  "credentials",
  "credentials-binding", # withCredentials(string / sshUserPrivateKey) — proof stages 3 + 5
  "plain-credentials",
  "ssh-credentials", # the sshUserPrivateKey credential type (gitops write key)
  # NOTE: deliberately NO "ssh-agent" plugin (it is "up for adoption"). The standard ModelMatch SSH
  # pattern is withCredentials([sshUserPrivateKey(...)]) + GIT_SSH_COMMAND, not the sshagent step.
]

# --- Network access ---
# admin_cidrs = Steve's laptop /32(s); keep in sync with platform/ public_access_cidrs (EKS endpoint).
# The laptop IP rotates (residential) — list approved source IPs here; prune stale entries.
# 8080 also opens to GitHub's published hook ranges for webhook delivery.
admin_cidrs = [
  "77.137.3.3/32",    # current
  "46.210.249.36/32",
  "87.71.200.38/32",
]

webhook_ingress_cidrs = [
  "192.30.252.0/22",
  "185.199.108.0/22",
  "140.82.112.0/20",
  "143.55.64.0/20",
]
webhook_ingress_ipv6_cidrs = [
  "2a0a:a440::/29",
  "2606:50c0::/32",
]

# --- Instance-role scope (mirrors platform IRSA role A for Bedrock) ---
bedrock_inference_profile_ids = ["apac.amazon.nova-lite-v1:0", "global.amazon.nova-2-lite-v1:0"]
bedrock_foundation_model_ids  = ["amazon.nova-lite-v1:0", "amazon.nova-2-lite-v1:0"]

# Pipeline-credential prefix in Secrets Manager (gitops deploy key, FE/BE read keys, webhook HMAC).
# FLAT, slash-free (modelmatch-jenkins-*): the Credentials Provider plugin forbids "/" in credential
# IDs (the secret name IS the id). The IAM glob in iam.tf scopes to "<prefix>-*".
jenkins_secret_prefix = "modelmatch-jenkins"
