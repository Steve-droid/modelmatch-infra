# P10 — ArgoCD installed via IaC + the root App-of-Apps seed.
#
# Two resources, in dependency order:
#   1. helm_release.argocd      — the upstream argo-cd chart (controller + CRDs + UI), installed LEAN.
#   2. helm_release.argocd_apps — seeds the ROOT Application (app-of-apps) pointing at gitops argocd/apps.
#
# The gitops repo is PUBLIC, so ArgoCD reads it over HTTPS anonymously — no repo credential / Secret.
#
# Why a 2nd Helm release for the root app (not kubernetes_manifest): kubernetes_manifest validates the
# Application CRD against the live API at PLAN time — but that CRD doesn't exist until argo-cd installs.
# A helm_release renders+applies at apply time, so with depends_on it survives a single clean apply (no
# CRD-ordering trap, no `-target` dance in the daily ritual). argocd-apps is an official argoproj chart
# (provider-yes / module-no permits upstream CHARTS).

locals {
  # Lean footprint for a 2-node t3a.medium cluster: drop SSO (dex) + the notifications controller, and
  # put modest requests/limits on every component (the upstream chart defaults them to {} = unbounded).
  argocd_values = {
    dex           = { enabled = false }
    notifications = { enabled = false }

    # App-of-Apps HEALTH: ArgoCD REMOVED built-in health assessment for argoproj.io/Application in v1.8,
    # so a parent app would otherwise show Healthy regardless of its children. Restore it with the
    # documented Lua health check (argocd-cm key resource.customizations.health.argoproj.io_Application)
    # so the root app's health reflects each child Application's health once children land (P11+).
    # Source: https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app-health
    configs = {
      cm = {
        "resource.customizations.health.argoproj.io_Application" = <<-EOT
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        EOT
      }
    }

    controller = {
      # The application-controller caches every resource of every managed Application in memory to
      # compute diffs. Adding kube-prometheus-stack (operator + CRDs + ~28 PrometheusRules + ServiceMonitors)
      # at P20 pushed its working set past the original 512Mi limit → OOMKilled (exit 137) crash-loop →
      # it could never finish a sync pass, so the `monitoring` app stayed OutOfSync. Bumped the limit to
      # 1.5Gi (headroom for the further P21–P23 observability objects) and the request to 512Mi (its real
      # floor is north of 512Mi). We're RAM-headroomed (only ~3 of 7.5GiB cluster RAM in use), so this
      # is the lean fix — raise the under-provisioned ceiling, not the node size.
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { cpu = "500m", memory = "1.5Gi" }
      }
    }
    server = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }
    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    applicationSet = {
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
  }
}

# 1. ArgoCD controller + CRDs + UI. Installs into the Terraform-owned `argocd` namespace.
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = var.argocd_namespace

  create_namespace = false # the namespace is owned by kubernetes_namespace.this["argocd"]
  timeout          = 600   # fresh nodes: image pulls + component startup can exceed the 300s default
  atomic           = true  # roll back a failed install so a re-apply starts clean

  values = [yamlencode(local.argocd_values)]

  depends_on = [kubernetes_namespace.this]
}

# The gitops repo is PUBLIC, so ArgoCD reads it over HTTPS anonymously — no repository credential, no
# Secret, no key in Terraform state. (The repo holds only Helm/Application manifests; app secrets arrive
# via ESO/Secrets Manager, never Git — so the repo is safe to be public.)

# 2. The root App-of-Apps Application — the single bootstrap seed that makes the rest declarative. It
#    watches gitops argocd/apps/ (empty skeleton at P10 -> Synced/Healthy with zero children) and
#    auto-syncs (prune + selfHeal). Child apps land in argocd/apps/ in P11 (ESO/ingress/cert-manager)
#    and P14 (the ModelMatch umbrella).
#    Child-app health propagates to this parent via the argoproj.io/Application health customization set
#    in local.argocd_values above (built-in Application health was removed in v1.8 — see that comment).
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = var.argocd_namespace

  values = [yamlencode({
    applications = {
      root = {
        namespace  = var.argocd_namespace
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_target_revision
          path           = var.gitops_apps_path
          directory      = { recurse = true }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.argocd_namespace
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  # argo-cd (incl. the Application CRD) must be fully applied before the root Application is created.
  depends_on = [helm_release.argocd]
}
