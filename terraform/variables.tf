variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "azure-aks-rg"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westeurope"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "azure-aks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the AKS cluster"
  type        = string
  default     = "1.34"
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "system_node_count" {
  description = "Number of nodes in the system node pool"
  type        = number
  default     = 3
}

variable "user_node_vm_size" {
  description = "VM size for the user (spot) node pool"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "user_node_min_count" {
  description = "Minimum number of nodes in the user node pool (autoscaler)"
  type        = number
  default     = 0
}

variable "user_node_max_count" {
  description = "Maximum number of nodes in the user node pool (autoscaler)"
  type        = number
  default     = 2
}

variable "acr_name" {
  description = "Name of the Azure Container Registry (must be globally unique, alphanumeric only)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    project     = "azure-aks"
    environment = "prod"
    managed_by  = "terraform"
  }
}
