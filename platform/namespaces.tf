# P10: the 4 cluster namespaces, all owned by Terraform (one owner — no double-management drift with
# ArgoCD). ArgoCD installs INTO the pre-created `argocd` ns (helm_release sets create_namespace=false +
# depends_on); child apps in P11+ target `app`/`monitoring`/`logging` WITHOUT CreateNamespace=true,
# since these already exist here.
#
#   argocd     -> ArgoCD itself (controller, repo-server, server, redis, applicationSet)
#   app        -> ModelMatch FE/BE/Postgres (P13/P14); MUST equal var.backend_namespace (IRSA role A subject)
#   monitoring -> Prometheus/Grafana (E13)
#   logging    -> EFK (E13)
resource "kubernetes_namespace" "this" {
  for_each = toset(var.kubernetes_namespaces)

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "modelmatch.dev/stack"         = "platform"
    }
  }
}
