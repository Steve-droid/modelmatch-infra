# Separate state: public DNS survives platform replacement. Domain registration
# and registrant contact details are deliberately outside Terraform.
terraform {
  backend "s3" {
    bucket       = "modelmatch-tfstate-957261948820"
    key          = "dns/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
