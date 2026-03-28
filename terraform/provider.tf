terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  backend "gcs" {}
  # Bucket and prefix are passed via -backend-config during init.
  # Locally: terraform init -backend-config=backend.conf
  # Pipeline: uses GCS_BUCKET secret
}

provider "azurerm" {
  features {}
  # OIDC auth is enabled via ARM_USE_OIDC env var in CI.
  # Locally, az login is used automatically.
}

# Uses kube_admin_config because Azure RBAC returns empty certs in kube_config.
# In production, store these credentials in Key Vault instead of relying on state.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_admin_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.main.kube_admin_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate)
  }
}
