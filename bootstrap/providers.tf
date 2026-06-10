# AWS provider for the bootstrap stack.
# default_tags stamps every taggable resource — the rubric requires owner/project/environment
# on every resource (FinOps tag-coverage + the orphan hunt depend on it); `stack` additionally
# distinguishes the persistent (bootstrap) vs ephemeral (platform) lifecycle for orphan-hunting.
# No `profile` here on purpose: auth comes from the default credential chain (env / ~/.aws),
# so nothing machine-specific is committed.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "bootstrap"
    }
  }
}
