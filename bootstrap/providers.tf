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

# AWS Budgets is a GLOBAL service whose backend lives in us-east-1, and a budget can only
# notify an SNS topic that also lives in us-east-1. This aliased provider exists solely to
# host the budget-alert SNS topic + subscription there (see sns.tf). Same default_tags so the
# topic is tagged identically to everything else in this stack.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "bootstrap"
    }
  }
}
