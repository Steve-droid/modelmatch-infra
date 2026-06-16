# P4: the Kubernetes control plane + workers on top of P3's network. Our own EKS module (no
# third-party modules). Workers + cluster ENIs land in the PRIVATE subnets only; values come from
# dev.tfvars via defaultless variables.
module "eks" {
  source = "../modules/eks"

  cluster_name = var.cluster_name
  k8s_version  = var.k8s_version

  # Workers/ENIs in the private subnets only (never public).
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access
  public_access_cidrs     = var.public_access_cidrs

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_max_pods       = var.node_max_pods
}
