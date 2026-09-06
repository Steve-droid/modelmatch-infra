# ECR repositories for the three ModelMatch images (FE / BE / agent). These live in the
# PERSISTENT bootstrap stack, never the daily destroy — the :1.0.0 images are the demo
# artifacts and must survive every platform teardown.
#
# History: in the bootcamp account the repos predated Terraform, so P5 adopted them via
# `terraform import`. In the Phase 2 account (957261948820, P32, 2026-09-06) nothing pre-exists,
# so this same module CREATES them; the repos start empty and P33 pushes the images.

module "ecr" {
  source = "../modules/ecr"

  repository_names = var.ecr_repository_names
  # mutability / scan / encryption / lifecycle numbers use the module defaults
  # (MUTABLE, scanOnPush=false, AES256, untagged>14d, keep last 10 tagged).
}
