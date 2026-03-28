data "azurerm_subscription" "current" {}

locals {
  # ACR names must be globally unique. Auto-generate from subscription ID if not provided.
  sub_short = substr(replace(data.azurerm_subscription.current.subscription_id, "-", ""), 0, 8)
  acr_name  = var.acr_name != null ? var.acr_name : "azureaks${local.sub_short}acr"
}

# Standard SKU is required for cache rules (Basic doesn't support them).
# Admin access is disabled — AKS authenticates via managed identity (AcrPull role below).
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = var.tags
}

# Grant AKS kubelet identity permission to pull images from ACR
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}

# Pull-through cache rules: ACR acts as a caching proxy for public registries.
# Images are pulled from ACR using the registry name as a path prefix:
#   myacr.azurecr.io/quay.io/prometheus/prometheus    -> cached from quay.io
#   myacr.azurecr.io/ghcr.io/org/image               -> cached from ghcr.io
# Docker Hub is excluded — Azure requires stored credentials for docker.io cache rules.
# In production, you'd create a Key Vault + credential set (outside Terraform to keep
# credentials out of state) and add credential_set_id to the cache rule.
# Docker Hub images (grafana, redis, nginx) are pulled directly.

resource "azurerm_container_registry_cache_rule" "quay" {
  name                  = "quay-io"
  container_registry_id = azurerm_container_registry.main.id
  source_repo           = "quay.io/*"
  target_repo           = "quay.io/*"
}

resource "azurerm_container_registry_cache_rule" "ghcr" {
  name                  = "ghcr-io"
  container_registry_id = azurerm_container_registry.main.id
  source_repo           = "ghcr.io/*"
  target_repo           = "ghcr.io/*"
}

resource "azurerm_container_registry_cache_rule" "k8s_registry" {
  name                  = "k8s-registry"
  container_registry_id = azurerm_container_registry.main.id
  source_repo           = "registry.k8s.io/*"
  target_repo           = "registry.k8s.io/*"
}
