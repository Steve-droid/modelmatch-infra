# ECR repositories for the three ModelMatch images (FE / BE / agent). These live in the
# PERSISTENT bootstrap stack, never the daily destroy — the :1.0.0 images are the demo
# artifacts and must survive every platform teardown.
#
# The repos already existed before Terraform (created during the smoke build), so P5 adopted
# them via `terraform import` rather than creating them; the module settings are matched to the
# live repos so that import was a no-op on the repositories themselves (only the lifecycle
# policies were added).

module "ecr" {
  source = "../modules/ecr"

  repository_names = var.ecr_repository_names
  # mutability / scan / encryption / lifecycle numbers use the module defaults
  # (MUTABLE, scanOnPush=false, AES256, untagged>14d, keep last 10 tagged).
}
