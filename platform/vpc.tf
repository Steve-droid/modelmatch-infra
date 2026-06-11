# P3: the network foundation every later platform resource sits on. Our own VPC module (no
# third-party modules) — values come from dev.tfvars via defaultless variables, never module defaults.
module "vpc" {
  source = "../modules/vpc"

  name_prefix     = var.vpc_name_prefix
  vpc_cidr        = var.vpc_cidr
  az_count        = var.az_count
  subnet_newbits  = var.subnet_newbits
  enable_eks_tags = var.enable_eks_tags
}
