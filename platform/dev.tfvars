# Concrete NON-SECRET values for the platform (ephemeral) stack.
# Passed EXPLICITLY: `terraform -chdir=platform plan|apply -var-file=dev.tfvars`
# (we do not rely on auto-loaded terraform.tfvars / *.auto.tfvars — Roey's rule, predictability).
# Committed on purpose: nothing here is a secret. Secrets reach the cluster via Secrets Manager
# (ESO + IRSA), never through tfvars.

aws_region = "ap-south-1"

# --- VPC (P3) ---
vpc_name_prefix = "modelmatch"
vpc_cidr        = "10.0.0.0/16"
az_count        = 2    # 2 AZs -> 2 public + 2 private subnets
subnet_newbits  = 4    # /16 + 4 = /20 subnets (4096 IPs each); 4 carved from the /16
enable_eks_tags = true # stamp kubernetes.io/role/*; cluster-name tag added in P4
