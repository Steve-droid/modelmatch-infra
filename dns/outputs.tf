output "zone_id" {
  value = aws_route53_zone.product.zone_id
}
output "name_servers" {
  description = "Verify these match the registrar delegation before cutover."
  value       = aws_route53_zone.product.name_servers
}
output "app_url" {
  value = "https://${var.app_hostname}"
}
output "api_url" {
  value = "https://${var.api_hostname}"
}
output "records_enabled" {
  value = var.records_enabled
}
output "additional_domains" {
  description = "Actual zone IDs/nameservers for registrar delegation; registration is separate."
  value = { for domain, zone in aws_route53_zone.additional : domain => {
    zone_id      = zone.zone_id
    name_servers = zone.name_servers
    app_url      = "https://${var.additional_domains[domain].app_hostname}"
    api_url      = "https://${var.additional_domains[domain].api_hostname}"
  } }
}
