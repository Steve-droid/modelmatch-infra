# Remote state backend for the platform stack — same bucket as bootstrap, different key,
# so the two stacks' states never collide. S3-native locking (use_lockfile, Terraform >= 1.10).
terraform {
  backend "s3" {
    bucket       = "modelmatch-tfstate-957261948820"
    key          = "platform/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
