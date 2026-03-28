## Overview

A production-grade Azure Kubernetes Service (AKS) cluster fully provisioned and managed through Terraform. Optimized for cost on a personal project that will be destroyed in hours.

## Architecture

### Terraform-Managed (Infrastructure)

- **Networking**: Custom VNet (10.0.0.0/16) with separate subnets for nodes and pods
- **AKS Cluster**: Free tier, Kubernetes 1.34, Azure CNI, Azure AD RBAC, workload identity
- **Node Pools**: System pool (1x Standard_D2s_v3) + User pool (0-2x Standard_D2s_v3 spot instances)
- **ACR**: Standard SKU with pull-through cache rules for quay.io, ghcr.io, registry.k8s.io (Docker Hub excluded — requires credentials). Name auto-generated from subscription ID.
- **Ingress**: Web Application Routing add-on (AKS native)
- **ArgoCD**: Deployed via Helm provider, images pulled through ACR cache
- **App-of-apps**: Rendered to local file and applied via `local-exec` provisioner

### ArgoCD-Managed (Applications)

- **Monitoring**: kube-prometheus-stack (Prometheus + Grafana) with minimal resource requests, images via ACR cache
- **Sample App**: nginx:alpine in dedicated namespace
- Application manifests use `${ACR_REGISTRY}` placeholders, rendered by the deploy pipeline ".github\workflows\deploy-apps.yaml"

### GitHub Actions Pipelines

- **Terraform**: On push to `terraform/` on `main` — runs `plan -out=tfplan` then `apply tfplan`
- **Deploy Apps**: On push to `applications/` on `main` — renders `${ACR_REGISTRY}` placeholders with real ACR login server, force-pushes to `deploy` branch
- **Destroy**: Manual trigger only — requires typing `destroy` to confirm
- All pipelines authenticate via OIDC (no stored keys)

## Project Structure

```
terraform/
  provider.tf              # Providers (azurerm, helm, kubernetes), GCS backend
  main.tf                  # Resource group
  variables.tf             # All variables with cost-optimized defaults
  outputs.tf               # kubeconfig, cluster FQDN, OIDC issuer URL, ACR login server
  network.tf               # VNet, node subnet, pod subnet
  aks.tf                   # AKS cluster, system pool, user spot pool
  acr.tf                   # ACR, AcrPull role, cache rules
  helm.tf                  # ArgoCD Helm release
  argocd_apps.tf           # App-of-apps via local_file + local-exec
  terraform.tfvars.example # Example variable values
applications/
  monitoring/
    kube-prometheus-stack.yaml  # ArgoCD Application for Prometheus + Grafana
  sample-app/
    namespace.yaml         # sample-app namespace
    deployment.yaml        # nginx:alpine via ${ACR_REGISTRY}
    service.yaml           # ClusterIP service
.github/workflows/
  terraform.yaml           # Plan + apply on push to terraform/
  deploy-apps.yaml         # Render ${ACR_REGISTRY} and push to deploy branch
  destroy.yaml             # Manual destroy with confirmation
```

## Key Design Decisions

1. **GCS backend for state**: Cross-cloud — bucket and prefix passed via `-backend-config` (no hardcoded values in code)
2. **OIDC everywhere**: Azure SP + GCP WIF, no stored credentials
3. **ACR pull-through cache**: Images from quay.io, ghcr.io, and registry.k8s.io flow through ACR. Docker Hub images are pulled directly (cache rules require stored credentials). In production, you'd add a Key Vault + credential set to cache Docker Hub images too.
4. **Web App Routing**: AKS-native add-on, no nginx ingress or cert-manager needed
5. **ArgoCD as GitOps engine**: Terraform bootstraps ArgoCD, app-of-apps watches the `deploy` branch for rendered manifests
6. **Spot instances**: User pool uses spot VMs with auto-scaling 0-2 nodes
7. **Free AKS tier**: No SLA, suitable for personal/dev workloads

## Deployment

See [README.md](README.md) for setup instructions. The pipelines handle `terraform apply` and application deployment automatically on push to `main`.

