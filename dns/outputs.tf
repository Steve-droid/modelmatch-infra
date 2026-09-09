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
