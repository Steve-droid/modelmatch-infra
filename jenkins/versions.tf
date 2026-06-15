# Terraform + provider constraints for the persistent jenkins/ stack. Same line as bootstrap/platform
# so all three roots pin one provider version. required_version >= 1.10 enables S3-native locking
# (use_lockfile) in backend.tf — no DynamoDB table.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
