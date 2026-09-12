# Modicum remains live; Driftplain was purchased and delegated on September 12, 2026.
# Non-secret values. Pass explicitly with -var-file=dev.tfvars.
aws_region      = "ap-south-1"
aws_account_id  = "957261948820"
domain_name     = "modicum.cloud"
app_hostname    = "modicum.cloud"
api_hostname    = "api.modicum.cloud"
records_enabled = true
additional_domains = {
  "driftplain.dev" = {
    app_hostname = "driftplain.dev"
    api_hostname = "api.driftplain.dev"
    # Public ownership proof supplied by Google Search Console on September 12, 2026.
    verification_txt = "google-site-verification=lq9EA-ghdeh0oRTy81xK-8rUU2gtptfVIjwLcwUy5ZA"
  }
}
# Read-only discovery on 2026-09-09. Re-run scripts/discover-ingress-dns.py after a rebuild.
ingress_nlb_arn = "arn:aws:elasticloadbalancing:ap-south-1:957261948820:loadbalancer/net/ad943b23d921d4914b93737030722b00/99ffa2a12cf35e54"
