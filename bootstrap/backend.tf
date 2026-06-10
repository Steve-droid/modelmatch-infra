# Remote state backend for the bootstrap stack — the bucket this stack itself created
# (chicken-and-egg resolved by create-then-migrate: applied once with local state, then
# `terraform init -migrate-state` moved the state here).
#
# Backend blocks can't use variables, so the values are literals (kept in sync with
# variables.tf / the platform backend). use_lockfile = true is S3-native locking (no DynamoDB).
terraform {
  backend "s3" {
    bucket       = "modelmatch-tfstate-832285994273"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
