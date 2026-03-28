resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Free tier — no SLA, suitable for dev/personal workloads
  sku_tier = "Free"
  tags     = var.tags

  default_node_pool {
    name           = "system"
    node_count     = var.system_node_count
    vm_size        = var.system_node_vm_size
    vnet_subnet_id = azurerm_subnet.nodes.id
    pod_subnet_id  = azurerm_subnet.pods.id

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI assigns pod IPs from the VNet, enabling direct pod-to-pod communication.
  # Network policy "azure" provides native network segmentation without third-party tools.
  # Service CIDR must not overlap with VNet (10.0.0.0/16) or pod subnet.
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  # Azure AD RBAC — uses Azure role assignments instead of Kubernetes RBAC
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_subscription.current.tenant_id
  }

  # OIDC + workload identity — lets pods authenticate to Azure services without stored credentials
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Web App Routing — AKS-native managed ingress (reverse proxy), replaces nginx ingress + cert-manager.
  # For custom domains: add an Azure DNS zone ID to dns_zone_ids, then create Ingress resources
  # with your hostname — Web App Routing auto-provisions TLS via Let's Encrypt.
  web_app_routing {
    dns_zone_ids = []
  }
}

# Spot instances — up to 90% cheaper than on-demand, Azure can evict with 30s notice.
# spot_max_price = -1 means pay up to the on-demand price. You still pay the current
# spot price (much lower), but -1 avoids unnecessary evictions from temporary price spikes.
# Taint ensures only workloads that explicitly tolerate spot scheduling land here.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_vm_size
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1
  auto_scaling_enabled  = true
  min_count             = var.user_node_min_count
  max_count             = var.user_node_max_count
  vnet_subnet_id        = azurerm_subnet.nodes.id
  pod_subnet_id         = azurerm_subnet.pods.id
  tags                  = var.tags

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]
}
