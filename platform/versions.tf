# Terraform + provider version constraints for the ephemeral platform stack.
# Kept identical to the bootstrap stack so both pin the same provider line.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Official provider (allowed — the module ban is on third-party MODULES, not providers).
    # Used by modules/eks to read the OIDC issuer's TLS cert thumbprint for the IAM OIDC provider.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # P10 — installs ArgoCD via the upstream argo-cd Helm chart (provider-yes / module-no: an official
    # PROVIDER + an upstream CHART is allowed; a community Terraform module is not). v2.x for the
    # well-documented nested `kubernetes {}` provider block.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # P10 — creates the 4 cluster namespaces ArgoCD + the app workloads live in.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}
