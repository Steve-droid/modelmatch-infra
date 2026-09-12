provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.home_server_account_id]
  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "home-server-identity"
    }
  }
}
