# P3: the network foundation every later platform resource sits on. Our own VPC module (no
# third-party modules) — values come from dev.tfvars via defaultless variables, never module defaults.
module "vpc" {
  source = "../modules/vpc"

  name_prefix     = var.vpc_name_prefix
  vpc_cidr        = var.vpc_cidr
  az_count        = var.az_count
  subnet_newbits  = var.subnet_newbits
  enable_eks_tags = var.enable_eks_tags

  # EKS cluster-ownership tag on both subnet tiers (used by LB subnet auto-discovery later).
  # Built from the cluster name here so the VPC module stays cluster-name-agnostic (P4 fork 4).
  public_subnet_extra_tags  = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
  private_subnet_extra_tags = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}
