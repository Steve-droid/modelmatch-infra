# Inputs for the platform (ephemeral) stack — declarations only. DEFAULTLESS by rule (Roey): no
# `default`s live here. Concrete NON-SECRET values are supplied explicitly via `-var-file=dev.tfvars`
# (we do NOT rely on auto-loaded terraform.tfvars / *.auto.tfvars). Secrets never go in tfvars.

variable "aws_region" {
  description = "AWS region for all resources in this stack."
  type        = string
}

variable "vpc_name_prefix" {
  description = "Prefix for the Name tag on VPC resources (e.g. \"modelmatch\" -> modelmatch-vpc)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.0.0.0/16). Subnets are carved from this with cidrsubnet()."
  type        = string
}

variable "az_count" {
  description = "Number of AZs to spread across (we use 2). One public + one private subnet per AZ."
  type        = number
}

variable "subnet_newbits" {
  description = "Bits cidrsubnet() adds to vpc_cidr per subnet (4 -> /16 becomes /20s)."
  type        = number
}

variable "enable_eks_tags" {
  description = "When true, stamp the EKS/LB discovery role tags on subnets (kubernetes.io/role/elb on public, internal-elb on private)."
  type        = bool
}

# --- EKS (P4) ---

variable "cluster_name" {
  description = "EKS cluster name. Also the value behind the kubernetes.io/cluster/<name> subnet ownership tag."
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes control-plane version — a latest in-support (STANDARD_SUPPORT) version, pinned explicitly here."
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
}

variable "node_desired_size" {
  description = "Desired worker node count at create."
  type        = number
}

variable "node_min_size" {
  description = "Minimum worker node count."
  type        = number
}

variable "node_max_size" {
  description = "Maximum worker node count."
  type        = number
}

variable "endpoint_public_access" {
  description = "Whether the cluster API endpoint is reachable from the public internet (narrowed by public_access_cidrs)."
  type        = bool
}

variable "endpoint_private_access" {
  description = "Whether the cluster API endpoint is reachable from inside the VPC."
  type        = bool
}

variable "public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint (e.g. the laptop IP as a /32)."
  type        = list(string)
}

# --- IRSA (P7) ---

variable "bedrock_inference_profile_ids" {
  description = "Inference-profile IDs the backend invokes (e.g. apac.amazon.nova-lite-v1:0, global.amazon.nova-2-lite-v1:0). Built into account-specific profile ARNs in role A's policy."
  type        = list(string)
}

variable "bedrock_foundation_model_ids" {
  description = "Foundation-model IDs the above profiles route to (e.g. amazon.nova-lite-v1:0). Built into region-wildcarded, model-pinned foundation-model ARNs in role A's policy."
  type        = list(string)
}

variable "app_secret_name" {
  description = "Secrets Manager secret name for the app's platform secrets (e.g. modelmatch/app). Role B is scoped to this name plus the random 6-char suffix glob."
  type        = string
}

variable "backend_namespace" {
  description = "Kubernetes namespace of the backend pod's ServiceAccount (role A trust subject)."
  type        = string
}

variable "backend_service_account" {
  description = "Name of the backend ServiceAccount (role A trust subject; annotated with role A in P14)."
  type        = string
}

variable "eso_namespace" {
  description = "Kubernetes namespace of the External Secrets Operator controller ServiceAccount (role B trust subject)."
  type        = string
}

variable "eso_service_account" {
  description = "Name of the ESO controller ServiceAccount (role B trust subject; used by the SecretStore in P12)."
  type        = string
}
