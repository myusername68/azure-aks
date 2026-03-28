# App-of-apps pattern: this single ArgoCD Application watches the deploy branch
# and automatically syncs all manifests under applications/. Adding a new app is
# just adding a folder — ArgoCD picks it up automatically.
#
# We use local_file + local-exec instead of kubernetes_manifest because the
# kubernetes provider can't plan resources when the cluster doesn't exist yet.
resource "local_file" "argocd_app_of_apps" {
  filename = "${path.module}/rendered/app-of-apps.yaml"
  content = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "app-of-apps"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/myusername68/azure-aks.git"
        targetRevision = "deploy"
        path           = "applications"
        directory = {
          recurse = true
        }
      }
      destination = {
        server = "https://kubernetes.default.svc"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })
}

# Apply the app-of-apps manifest to the cluster after ArgoCD is running
resource "terraform_data" "apply_argocd_apps" {
  triggers_replace = [
    local_file.argocd_app_of_apps.content,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --admin --overwrite-existing
      kubectl apply -f ${local_file.argocd_app_of_apps.filename}
    EOT
  }

  depends_on = [helm_release.argocd]
}
