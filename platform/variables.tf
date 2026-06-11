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
