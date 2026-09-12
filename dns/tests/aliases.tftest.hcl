mock_provider "aws" {
  mock_data "aws_lb" {
    defaults = {
      dns_name           = "ingress.elb.ap-south-1.amazonaws.com"
      zone_id            = "Z-NLB-TEST"
      internal           = false
      load_balancer_type = "network"
    }
  }
}

run "app_and_api_alias_existing_nlb" {
  command = plan
  assert {
    condition     = length(aws_route53_record.ingress) == 2
    error_message = "Only the app and API records should be created."
  }
  assert {
    condition     = aws_route53_record.ingress["app"].name == "modicum.cloud" && aws_route53_record.ingress["api"].name == "api.modicum.cloud"
    error_message = "Public hostnames drifted from the selected Modicum domain."
  }
  assert {
    condition     = aws_route53_record.ingress["app"].alias[0].name == "ingress.elb.ap-south-1.amazonaws.com" && aws_route53_record.ingress["app"].alias[0].zone_id == "Z-NLB-TEST"
    error_message = "Alias must use the existing LB's DNS and canonical zone, not an IP."
  }
}

run "teardown_preserves_zone_without_querying_deleted_lb" {
  command = plan
  variables {
    records_enabled = false
  }
  assert {
    condition     = length(aws_route53_record.ingress) == 0 && length(data.aws_lb.ingress) == 0
    error_message = "Disabled DNS must drop aliases and not require a still-existing LB."
  }
  assert {
    condition     = aws_route53_zone.product.name == "modicum.cloud"
    error_message = "The persistent zone must remain."
  }
}

run "reject_external_hostname" {
  command = plan
  variables {
    api_hostname = "api.other.cloud"
  }
  expect_failures = [aws_route53_record.ingress]
}

run "reject_duplicate_names" {
  command = plan
  variables {
    api_hostname = "modicum.cloud"
  }
  expect_failures = [aws_route53_record.ingress]
}

run "reject_internal_nlb" {
  command = plan
  override_data {
    target = data.aws_lb.ingress[0]
    values = {
      dns_name           = "internal.elb.ap-south-1.amazonaws.com"
      zone_id            = "Z-NLB-TEST"
      internal           = true
      load_balancer_type = "network"
    }
  }
  expect_failures = [aws_route53_record.ingress, aws_route53_record.additional]
}

run "reject_non_network_lb" {
  command = plan
  override_data {
    target = data.aws_lb.ingress[0]
    values = {
      dns_name           = "application.elb.ap-south-1.amazonaws.com"
      zone_id            = "Z-NLB-TEST"
      internal           = false
      load_balancer_type = "application"
    }
  }
  expect_failures = [aws_route53_record.ingress, aws_route53_record.additional]
}

run "rebrand_adds_domain_and_preserves_original" {
  command = plan
  assert {
    condition = aws_route53_zone.product.name == "modicum.cloud" && length(aws_route53_record.ingress) == 2 && length(aws_route53_zone.additional) == 1 && length(aws_route53_record.additional) == 2
    error_message = "The original zone/aliases must survive alongside the new domain."
  }
  assert {
    condition = aws_route53_record.additional["driftplain.dev/api"].name == "api.driftplain.dev" && aws_route53_record.additional["driftplain.dev/app"].alias[0].name == aws_route53_record.ingress["app"].alias[0].name
    error_message = "New domain must use the same existing ingress load balancer."
  }
}
run "disable_all_aliases_preserves_both_zones" {
  command = plan
  variables { records_enabled = false }
  assert {
    condition = length(aws_route53_record.ingress) == 0 && length(aws_route53_record.additional) == 0 && length(data.aws_lb.ingress) == 0 && length(aws_route53_zone.additional) == 1
    error_message = "Teardown must remove aliases for both domains without destroying zones or reading the old NLB."
  }
}
run "original_domain_only_remains_supported" {
  command = plan
  variables { additional_domains = {} }
  assert {
    condition = length(aws_route53_zone.additional) == 0 && length(aws_route53_record.additional) == 0 && length(aws_route53_record.ingress) == 2
    error_message = "Empty additional_domains must preserve the original configuration."
  }
}
run "reject_additional_external_host" {
  command = plan
  variables {
    additional_domains = { "driftplain.dev" = { app_hostname = "driftplain.dev", api_hostname = "api.other.dev" } }
  }
  expect_failures = [var.additional_domains]
}
run "reject_additional_duplicate_host" {
  command = plan
  variables {
    additional_domains = { "driftplain.dev" = { app_hostname = "driftplain.dev", api_hostname = "driftplain.dev" } }
  }
  expect_failures = [var.additional_domains]
}
run "reject_reusing_original_zone" {
  command = plan
  variables {
    additional_domains = { "modicum.cloud" = { app_hostname = "modicum.cloud", api_hostname = "api.modicum.cloud" } }
  }
  expect_failures = [var.additional_domains]
}
