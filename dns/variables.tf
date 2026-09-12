variable "aws_region" {
  description = "Region of the existing ingress NLB. Route 53 itself is global."
  type        = string
}
variable "aws_account_id" {
  description = "Expected AWS account; provider rejects credentials for another account."
  type        = string
}
variable "domain_name" {
  description = "Registered domain whose public zone this stack owns (registration is separate)."
  type        = string
  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain_name))
    error_message = "Use a lowercase DNS domain without a scheme, path, or trailing dot."
  }
}
variable "app_hostname" {
  description = "App hostname, either the zone apex or a name inside the zone."
  type        = string
}
variable "additional_domains" {
  description = "Additional product domains retained alongside the original zone during rebrands."
  type = map(object({
    app_hostname     = string
    api_hostname     = string
    verification_txt = optional(string)
  }))
  validation {
    condition = alltrue([for domain, hosts in var.additional_domains :
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", domain)) &&
      (hosts.verification_txt == null || can(regex("^google-site-verification=[A-Za-z0-9_-]{1,200}$", hosts.verification_txt))) &&
      domain != var.domain_name && hosts.app_hostname != hosts.api_hostname &&
      alltrue([for host in [hosts.app_hostname, hosts.api_hostname] :
        can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", host)) &&
        (host == domain || endswith(host, ".${domain}"))
      ])
    ])
    error_message = "Additional domains must differ from the original zone and contain two distinct, valid app/API hostnames."
  }
}
variable "api_hostname" {
  description = "API hostname inside the zone, distinct from the app hostname."
  type        = string
}
variable "records_enabled" {
  description = "False removes the two NLB aliases before final platform teardown; keeps the zone."
  type        = bool
}
variable "ingress_nlb_arn" {
  description = "Verified ARN of the Kubernetes-owned ingress NLB. Read-only lookup, never a resource."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:elasticloadbalancing:[a-z0-9-]+:[0-9]{12}:loadbalancer/net/", var.ingress_nlb_arn))
    error_message = "Supply a Network Load Balancer ARN from the ingress Service, not a hostname or IP."
  }
}
