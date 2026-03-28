# ArgoCD is the GitOps engine — Terraform bootstraps it, then ArgoCD manages all applications.
# Exposed via LoadBalancer for direct access. In production, use Ingress with TLS instead.
# server.insecure disables ArgoCD's built-in TLS since we're not terminating TLS at ArgoCD.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.4.17"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  # ArgoCD images come from quay.io — pulled through ACR cache.
  # Redis comes from docker.io — pulled directly (Docker Hub cache rules require credentials).
  values = [yamlencode({
    server = {
      service = {
        type = "LoadBalancer"
      }
    }
    configs = {
      params = {
        "server.insecure" = true
      }
    }
    global = {
      image = {
        registry = "${azurerm_container_registry.main.login_server}/quay.io"
      }
    }
  })]

  # Cluster, nodes, ACR permissions, and cache rules must all be ready before deploying ArgoCD
  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_container_registry_cache_rule.quay,
  ]
}
