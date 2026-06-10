# Terraform + provider version constraints for the ephemeral platform stack.
# Kept identical to the bootstrap stack so both pin the same provider line.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
