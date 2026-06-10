# AWS provider for the platform (ephemeral) stack — apply at day start, destroy at day end.
# Same default_tags contract as bootstrap; `stack = platform` marks the ephemeral lifecycle.
# No `profile` — auth via the default credential chain (env / ~/.aws).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "platform"
    }
  }
}
