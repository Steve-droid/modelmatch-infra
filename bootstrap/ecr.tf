# ECR repositories for the four ModelMatch images (FE / BE / agent / agent-security). These live in the
# PERSISTENT bootstrap stack, never the daily destroy — the :1.0.0 images are the demo
# artifacts and must survive every platform teardown.
#
# History: in the bootcamp account the repos predated Terraform, so P5 adopted them via
# `terraform import`. In the Phase 2 account (957261948820, P32, 2026-09-06) nothing pre-exists,
# so this same module CREATES them; the repos start empty and P33 pushes the images.
# P38d (2026-09-08) split the agent into two images; `modelmatch-agent-security` was created by a
# one-off `aws ecr create-repository` with identical settings + lifecycle policy, then adopted:
#   terraform -chdir=bootstrap import -var-file=dev.tfvars \
#     'module.ecr.aws_ecr_repository.this["modelmatch-agent-security"]' modelmatch-agent-security
#   terraform -chdir=bootstrap import -var-file=dev.tfvars \
#     'module.ecr.aws_ecr_lifecycle_policy.this["modelmatch-agent-security"]' modelmatch-agent-security
# The only post-import diff is the `stack` tag (manual-p38d -> bootstrap), an in-place update.

module "ecr" {
  source = "../modules/ecr"

  repository_names = var.ecr_repository_names
  # mutability / scan / encryption / lifecycle numbers use the module defaults
  # (MUTABLE, scanOnPush=false, AES256, untagged>14d, keep last 10 tagged).
}
