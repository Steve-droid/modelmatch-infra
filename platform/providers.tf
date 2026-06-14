# AWS provider for the platform (ephemeral) stack — apply at day start, destroy at day end.
# Same default_tags contract as bootstrap; `stack = platform` marks the ephemeral lifecycle.
# No `profile` — auth via the default credential chain (env / ~/.aws).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "platform"
    }
  }
}

# --- P10: Kubernetes + Helm providers, authed to the EKS cluster created in THIS stack ---------------
# Both read the cluster endpoint + CA straight off the eks module's resource outputs (already in state
# by the time any ArgoCD resource plans), and mint a short-lived token via `aws eks get-token` at apply
# time (exec plugin — no long-lived kubeconfig, matches the no-static-keys rule). The OIDC issuer
# regenerates on every cluster rebuild, but these reference module.eks dynamically, so nothing is pinned.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
