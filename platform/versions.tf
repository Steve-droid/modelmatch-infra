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
  }
}
