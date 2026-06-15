# Remote state for the jenkins/ stack — same bucket as bootstrap/platform, a THIRD key so the three
# states never collide. S3-native locking (use_lockfile, Terraform >= 1.10). Backend blocks accept
# only literals (no variables/remote_state), so bucket/key/region are hardcoded and kept in sync with
# the other two backend.tf files by hand (see modelmatch-infra/CLAUDE.md).
terraform {
  backend "s3" {
    bucket       = "modelmatch-tfstate-832285994273"
    key          = "jenkins/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
