# Persistent identity lifecycle, independent of platform/ and bootstrap/.
# Local tests use init -backend=false; no remote state has been initialized/applied.
terraform {
  backend "s3" {
    bucket       = "modelmatch-tfstate-957261948820"
    key          = "home-server/identity/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
