# Our own reusable IRSA-role module (no third-party modules — Roey's hard rule).
#
# IRSA (IAM Roles for Service Accounts): a Kubernetes ServiceAccount assumes an IAM role through the
# cluster's OIDC provider, so in-cluster pods get scoped AWS access with NO static keys. The trust
# shape is copied from modules/eks aws_iam_role.ebs_csi:
#   - Federated principal = the OIDC provider ARN
#   - Action sts:AssumeRoleWithWebIdentity
#   - StringEquals conditions pinning the EXACT namespace:serviceaccount (:sub) and the STS
#     audience (:aud = sts.amazonaws.com) — so only that one SA can assume the role.
# One inline permission policy (policy_json) is attached; the calling stack scopes it to exact ARNs.

locals {
  # OIDC condition keys use the issuer host WITHOUT the https:// scheme.
  oidc_host = replace(var.oidc_issuer_url, "https://", "")
}

resource "aws_iam_role" "this" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account}"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Inline (not managed) policy: it lives and dies with the role and is purpose-built for this SA —
# nothing else should attach to it. Least-privilege ARNs are enforced by the caller via policy_json.
resource "aws_iam_role_policy" "this" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
