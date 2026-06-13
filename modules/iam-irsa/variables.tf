# Inputs for the reusable IRSA-role module — declarations only, NO defaults (Roey's rule). Every
# value is supplied by the calling stack (platform/), never a module default. This is the module
# interface: an OIDC-federated IAM role bound to ONE namespace:serviceaccount, plus one inline policy.

variable "role_name" {
  description = "Name of the IAM role (e.g. \"modelmatch-backend-irsa\")."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider — the Federated principal in the trust policy."
  type        = string
}

variable "oidc_issuer_url" {
  description = "Cluster OIDC issuer URL (https://...); the https:// scheme is stripped to form the :sub/:aud condition keys."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume this role."
  type        = string
}

variable "service_account" {
  description = "Name of the ServiceAccount (within namespace) allowed to assume this role."
  type        = string
}

variable "policy_json" {
  description = "The inline permission policy document (JSON) attached to the role — scoped to exact ARNs by the caller."
  type        = string
}
