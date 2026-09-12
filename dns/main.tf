# Registered at Porkbun. Create the public zone here, then delegate at the registrar
# to this zone's actual nameservers. Check for an existing zone first (see README).
resource "aws_route53_zone" "product" {
  name    = var.domain_name
  comment = "Modicum public app and API; managed by the persistent DNS stack"
  lifecycle {
    prevent_destroy = true
  }
}

# The Kubernetes service controller owns this LB. Terraform only looks it up.
data "aws_lb" "ingress" {
  count = var.records_enabled ? 1 : 0
  arn   = var.ingress_nlb_arn
}

locals {
  hosts = {
    app = var.app_hostname
    api = var.api_hostname
  }
  additional_hosts = merge({}, [for domain, hosts in var.additional_domains : {
    for role, host in { app = hosts.app_hostname, api = hosts.api_hostname } :
    "${domain}/${role}" => { domain = domain, hostname = host }
  }]...)
}

# A rebrand adds a separate zone; the original zone and resource addresses stay
# intact so existing app sessions and pasted CI snippets keep their endpoints.
resource "aws_route53_zone" "additional" {
  for_each = var.additional_domains
  name     = each.key
  comment  = "Product app and API; managed by the persistent DNS stack"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "additional" {
  for_each = var.records_enabled ? local.additional_hosts : {}
  zone_id  = aws_route53_zone.additional[each.value.domain].zone_id
  name     = each.value.hostname
  type     = "A"
  alias {
    name                   = data.aws_lb.ingress[0].dns_name
    zone_id                = data.aws_lb.ingress[0].zone_id
    evaluate_target_health = false
  }
  lifecycle {
    precondition {
      condition     = !data.aws_lb.ingress[0].internal && data.aws_lb.ingress[0].load_balancer_type == "network"
      error_message = "DNS must target the existing internet-facing ingress Network Load Balancer."
    }
  }
}

resource "aws_route53_record" "ingress" {
  for_each = var.records_enabled ? local.hosts : {}
  zone_id  = aws_route53_zone.product.zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = data.aws_lb.ingress[0].dns_name
    zone_id                = data.aws_lb.ingress[0].zone_id
    evaluate_target_health = false
  }
  lifecycle {
    precondition {
      condition = (
        can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", each.value)) &&
        (each.value == var.domain_name || endswith(each.value, ".${var.domain_name}")) &&
        var.app_hostname != var.api_hostname
      )
      error_message = "App/API names must be distinct, valid DNS names in the product zone."
    }
    precondition {
      condition     = !data.aws_lb.ingress[0].internal && data.aws_lb.ingress[0].load_balancer_type == "network"
      error_message = "DNS must target the existing internet-facing ingress Network Load Balancer."
    }
  }
}

# Public Google ownership proof persists through platform teardown with the zone.
resource "aws_route53_record" "additional_verification" {
  for_each = { for domain, hosts in var.additional_domains : domain => hosts.verification_txt if hosts.verification_txt != null }
  zone_id  = aws_route53_zone.additional[each.key].zone_id
  name     = each.key
  type     = "TXT"
  ttl      = 300
  records  = [each.value]
}
