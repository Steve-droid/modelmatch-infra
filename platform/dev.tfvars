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
enable_eks_tags = true # stamp kubernetes.io/role/*; cluster-name tag passed to the VPC module in P4

# --- EKS (P4) ---
cluster_name = "modelmatch"
k8s_version  = "1.36" # latest in-support (STANDARD_SUPPORT) as of 2026-06-13; NOT extended support

node_instance_types = ["t3a.medium"]
node_desired_size   = 2 # start 2
node_min_size       = 2
node_max_size       = 3 # cap at 3

# API endpoint: public + private, but the public surface is narrowed to approved source IPs.
endpoint_public_access  = true
endpoint_private_access = true
public_access_cidrs     = ["5.29.38.37/32"] # Steve's laptop public IP — update if it changes
