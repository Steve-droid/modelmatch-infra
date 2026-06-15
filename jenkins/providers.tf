# AWS provider for the persistent jenkins/ stack (the graded CI controller). Same default_tags
# contract as bootstrap/platform; `stack = jenkins` marks this third lifecycle — persistent, but a
# SEPARATE root so the daily `platform` destroy can never reach it, and so the orphan hunt can tell
# Jenkins resources apart. No `profile` — auth via the default credential chain (env / ~/.aws).
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      owner       = "steve"
      project     = "modelmatch"
      environment = "dev"
      stack       = "jenkins"
    }
  }
}
