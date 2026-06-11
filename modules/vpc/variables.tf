# Inputs for our own VPC module (no third-party/registry modules — Roey's hard rule).
# DEFAULTLESS by rule: every concrete value is supplied by the calling stack's values.tf
# (locals), never via a `default` here — keeps applies predictable.

variable "name_prefix" {
  description = "Prefix for the Name tag on every resource (e.g. \"modelmatch\" -> modelmatch-vpc, modelmatch-public-<az>)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.0.0.0/16). Subnets are carved from this with cidrsubnet()."
  type        = string
}

variable "az_count" {
  description = "Number of AZs to spread across (we use 2). Drives one public + one private subnet per AZ."
  type        = number
}

variable "subnet_newbits" {
  description = "Bits added to vpc_cidr by cidrsubnet() for each subnet (4 -> /16 becomes /20s). 2*az_count subnets are carved: public take indexes 0..az_count-1, private take az_count..2*az_count-1."
  type        = number
}

variable "enable_eks_tags" {
  description = "When true, stamp the EKS/LB discovery role tags: kubernetes.io/role/elb=1 on public subnets, kubernetes.io/role/internal-elb=1 on private subnets. The cluster-name tag is added in P4 when the cluster name exists."
  type        = bool
}
