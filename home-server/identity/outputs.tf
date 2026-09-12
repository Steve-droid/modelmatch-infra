output "home_server_identity" {
  description = "Public runtime metadata only; empty until reviewed provisioning."
  value = { for name, role in aws_iam_role.home_server : name => {
    role_arn         = role.arn
    profile_arn      = aws_rolesanywhere_profile.home_server[name].arn
    trust_anchor_arn = aws_rolesanywhere_trust_anchor.home_server[0].arn
    certificate_cn   = local.home_server_subjects[name]
    region           = var.aws_region
  } }
}
