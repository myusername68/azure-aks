#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# init.sh - Set up all prerequisites for the azure-aks project
#
# Creates:
#   - Azure AD app registration + service principal + role assignments
#   - Azure OIDC federated credential for GitHub Actions
#   - GCP Workload Identity Federation (pool, provider, service account, bindings)
#   - Outputs all variables to .env file
#   - Optionally sets GitHub repo secrets via gh CLI
#
# Usage:
#   ./init.sh                          # Setup Azure + GCP, output to .env
#   ./init.sh --github                 # Also set GitHub repo secrets
#   ./init.sh --github --repo owner/repo  # Specify a different repo
#
# Idempotent: safe to re-run if a step fails.
# =============================================================================

# --- Configuration -----------------------------------------------------------

AZURE_APP_NAME="azure-aks-terraform"
GCS_BUCKET="artium-projects-terraform-backend"
GCP_WIF_POOL="github-actions"
GCP_WIF_PROVIDER="github-oidc"
GCP_SA_NAME="terraform-azure"
GITHUB_REPO="myusername68/azure-aks"
ENV_FILE=".env"
SETUP_GITHUB=false

# --- Parse arguments ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case $1 in
    --github)
      SETUP_GITHUB=true
      shift
      ;;
    --repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./init.sh [--github] [--repo owner/repo]"
      exit 1
      ;;
  esac
done

# --- Helpers -----------------------------------------------------------------

info()  { echo -e "\n\033[1;34m[INFO]\033[0m $1"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

check_tool() {
  if ! command -v "$1" &>/dev/null; then
    error "$1 is required but not installed. See README.md for install instructions."
  fi
}

# --- Preflight checks --------------------------------------------------------

info "Checking required tools..."
check_tool az
check_tool gcloud
check_tool terraform

if [[ "$SETUP_GITHUB" == true ]]; then
  check_tool gh
fi

# --- Interactive login -------------------------------------------------------

login_if_needed() {
  local name="$1" check_cmd="$2" login_cmd="$3"

  if eval "$check_cmd" &>/dev/null; then
    ok "$name already authenticated"
    return
  fi

  warn "$name is not authenticated"
  read -rp "  Run '$login_cmd' now? [Y/n] " answer
  if [[ -n "$answer" && ! "$answer" =~ ^[Yy]$ ]]; then
    error "$name authentication required. Aborting."
  fi

  # Disable exit-on-error for the login command — it may return non-zero
  # transiently (e.g. browser issues) while still completing successfully.
  set +e
  eval "$login_cmd"
  set -e

  if eval "$check_cmd" &>/dev/null; then
    ok "$name authenticated"
  else
    error "$name login failed"
  fi
}

info "Checking authentication..."

login_if_needed "Azure CLI" "az account show" "az login"
login_if_needed "Google Cloud" "gcloud auth list --filter='status:ACTIVE' --format='value(account)' | grep -q ." "gcloud auth login"

if [[ "$SETUP_GITHUB" == true ]]; then
  login_if_needed "GitHub CLI" "gh auth status" "BROWSER='' gh auth login --git-protocol https"
fi

# --- Gather and confirm account info -----------------------------------------

info "Gathering account information..."

AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
AZURE_SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
AZURE_TENANT_ID="$(az account show --query tenantId -o tsv)"
GCP_PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [[ -z "$GCP_PROJECT_ID" ]]; then
  error "No GCP project set. Run: gcloud config set project <PROJECT_ID>"
fi

GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")

echo ""
echo "  Azure Subscription: $AZURE_SUBSCRIPTION_NAME ($AZURE_SUBSCRIPTION_ID)"
echo "  Azure Tenant:       $AZURE_TENANT_ID"
echo "  GCP Project:        $GCP_PROJECT_ID ($GCP_PROJECT_NUMBER)"
if [[ "$SETUP_GITHUB" == true ]]; then
  echo "  GitHub Repo:        $GITHUB_REPO"
fi
echo ""
read -rp "Are these correct? [Y/n] " confirm
if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
  # Azure subscription selection
  info "Available Azure subscriptions:"
  az account list --query "[].{Name:name, Id:id, IsDefault:isDefault}" -o table
  echo ""
  read -rp "Enter Azure subscription ID (or press Enter to keep current): " new_sub
  if [[ -n "$new_sub" ]]; then
    az account set --subscription "$new_sub"
    AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    AZURE_SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
    ok "Switched to: $AZURE_SUBSCRIPTION_NAME ($AZURE_SUBSCRIPTION_ID)"
  fi

  # GCP project selection
  info "Available GCP projects:"
  gcloud projects list --format="table(projectId, name)"
  echo ""
  read -rp "Enter GCP project ID (or press Enter to keep current): " new_project
  if [[ -n "$new_project" ]]; then
    gcloud config set project "$new_project"
    GCP_PROJECT_ID="$new_project"
    GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
    ok "Switched to: $GCP_PROJECT_ID ($GCP_PROJECT_NUMBER)"
  fi

  # GitHub repo selection
  if [[ "$SETUP_GITHUB" == true ]]; then
    info "Available GitHub repos:"
    gh repo list --limit 20 --json nameWithOwner --jq '.[].nameWithOwner'
    echo ""
    read -rp "Enter GitHub repo (owner/name) (or press Enter to keep '$GITHUB_REPO'): " new_repo
    if [[ -n "$new_repo" ]]; then
      GITHUB_REPO="$new_repo"
      ok "Switched to: $GITHUB_REPO"
    fi
  fi

  echo ""
  echo "  Azure Subscription: $AZURE_SUBSCRIPTION_NAME ($AZURE_SUBSCRIPTION_ID)"
  echo "  Azure Tenant:       $AZURE_TENANT_ID"
  echo "  GCP Project:        $GCP_PROJECT_ID ($GCP_PROJECT_NUMBER)"
  if [[ "$SETUP_GITHUB" == true ]]; then
    echo "  GitHub Repo:        $GITHUB_REPO"
  fi
  echo ""
fi

# =============================================================================
# AZURE SETUP
# =============================================================================

info "Setting up Azure AD app registration..."

# Create app registration if it doesn't exist
AZURE_CLIENT_ID=$(az ad app list --display-name "$AZURE_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null)

if [[ -z "$AZURE_CLIENT_ID" ]]; then
  az ad app create --display-name "$AZURE_APP_NAME" --output none
  AZURE_CLIENT_ID=$(az ad app list --display-name "$AZURE_APP_NAME" --query "[0].appId" -o tsv)
  ok "Created app registration: $AZURE_APP_NAME ($AZURE_CLIENT_ID)"
else
  ok "App registration already exists: $AZURE_APP_NAME ($AZURE_CLIENT_ID)"
fi

AZURE_OBJECT_ID=$(az ad app list --display-name "$AZURE_APP_NAME" --query "[0].id" -o tsv)

# Create service principal if it doesn't exist
info "Setting up service principal..."

if az ad sp show --id "$AZURE_CLIENT_ID" &>/dev/null; then
  ok "Service principal already exists"
else
  az ad sp create --id "$AZURE_CLIENT_ID" --output none
  ok "Created service principal"
fi

# Assign Contributor role (idempotent - Azure won't duplicate)
info "Assigning Azure roles..."

az role assignment create \
  --assignee "$AZURE_CLIENT_ID" \
  --role "Contributor" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
  --output none 2>/dev/null || true
ok "Contributor role assigned"

az role assignment create \
  --assignee "$AZURE_CLIENT_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
  --output none 2>/dev/null || true
ok "User Access Administrator role assigned"

# Create OIDC federated credential for GitHub Actions
info "Setting up OIDC federated credential for GitHub Actions..."

EXISTING_CRED=$(az ad app federated-credential list --id "$AZURE_OBJECT_ID" --query "[?name=='github-actions'].name" -o tsv 2>/dev/null)

if [[ -z "$EXISTING_CRED" ]]; then
  az ad app federated-credential create --id "$AZURE_OBJECT_ID" --parameters "{
    \"name\": \"github-actions\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
  ok "Created OIDC federated credential for $GITHUB_REPO"
else
  ok "OIDC federated credential already exists"
fi

# =============================================================================
# GCP SETUP
# =============================================================================

info "Setting up GCP Workload Identity Federation..."

# Create Workload Identity Pool
if gcloud iam workload-identity-pools describe "$GCP_WIF_POOL" \
    --project="$GCP_PROJECT_ID" --location="global" &>/dev/null; then
  ok "Workload Identity Pool already exists: $GCP_WIF_POOL"
else
  gcloud iam workload-identity-pools create "$GCP_WIF_POOL" \
    --project="$GCP_PROJECT_ID" \
    --location="global" \
    --display-name="GitHub Actions"
  ok "Created Workload Identity Pool: $GCP_WIF_POOL"
fi

# Create OIDC Provider
info "Setting up Workload Identity Provider..."

if gcloud iam workload-identity-pools providers describe "$GCP_WIF_PROVIDER" \
    --project="$GCP_PROJECT_ID" --location="global" \
    --workload-identity-pool="$GCP_WIF_POOL" &>/dev/null; then
  ok "Workload Identity Provider already exists: $GCP_WIF_PROVIDER"
else
  gcloud iam workload-identity-pools providers create-oidc "$GCP_WIF_PROVIDER" \
    --project="$GCP_PROJECT_ID" \
    --location="global" \
    --workload-identity-pool="$GCP_WIF_POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
  ok "Created Workload Identity Provider: $GCP_WIF_PROVIDER"
fi

# Create service account
info "Setting up GCP service account..."

GCP_SA_EMAIL="${GCP_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$GCP_SA_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
  ok "Service account already exists: $GCP_SA_EMAIL"
else
  gcloud iam service-accounts create "$GCP_SA_NAME" \
    --project="$GCP_PROJECT_ID" \
    --display-name="Terraform State Access"
  ok "Created service account: $GCP_SA_EMAIL"
fi

# Grant service account access to GCS bucket
info "Granting GCS bucket access..."

gsutil iam ch \
  "serviceAccount:${GCP_SA_EMAIL}:roles/storage.objectAdmin" \
  "gs://${GCS_BUCKET}" 2>/dev/null
ok "Service account has storage.objectAdmin on gs://${GCS_BUCKET}"

# Bind WIF to service account
info "Binding Workload Identity to service account..."

WIF_MEMBER="principalSet://iam.googleapis.com/projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${GCP_WIF_POOL}/attribute.repository/${GITHUB_REPO}"

gcloud iam service-accounts add-iam-policy-binding "$GCP_SA_EMAIL" \
  --project="$GCP_PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$WIF_MEMBER" 2>/dev/null || true
ok "Workload Identity bound to service account"

# Build the full provider path
GCP_WIF_PROVIDER_FULL="projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${GCP_WIF_POOL}/providers/${GCP_WIF_PROVIDER}"

# =============================================================================
# OUTPUT
# =============================================================================

info "Writing variables to ${ENV_FILE}..."

cat > "$ENV_FILE" <<EOF
# Generated by init.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Do not commit this file.

# Azure
AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
AZURE_TENANT_ID=${AZURE_TENANT_ID}
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}

# Azure - Terraform env vars (export these before running terraform)
ARM_CLIENT_ID=${AZURE_CLIENT_ID}
ARM_TENANT_ID=${AZURE_TENANT_ID}
ARM_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}

# GCP
GCP_PROJECT_ID=${GCP_PROJECT_ID}
GCP_PROJECT_NUMBER=${GCP_PROJECT_NUMBER}
GCP_WORKLOAD_IDENTITY_PROVIDER=${GCP_WIF_PROVIDER_FULL}
GCP_SERVICE_ACCOUNT=${GCP_SA_EMAIL}

# Terraform backend
GCS_BUCKET=${GCS_BUCKET}
EOF

ok "Variables written to ${ENV_FILE}"

# Generate Terraform backend config
info "Writing Terraform backend config..."

cat > "terraform/backend.conf" <<EOF
bucket = "${GCS_BUCKET}"
prefix = "azure-terraform"
EOF

ok "Backend config written to terraform/backend.conf"

# =============================================================================
# GITHUB SECRETS (optional)
# =============================================================================

if [[ "$SETUP_GITHUB" == true ]]; then
  info "The following secrets will be set on ${GITHUB_REPO}:"
  echo ""
  echo "  AZURE_CLIENT_ID                = ${AZURE_CLIENT_ID}"
  echo "  AZURE_TENANT_ID                = ${AZURE_TENANT_ID}"
  echo "  AZURE_SUBSCRIPTION_ID          = ${AZURE_SUBSCRIPTION_ID}"
  echo "  GCP_WORKLOAD_IDENTITY_PROVIDER = ${GCP_WIF_PROVIDER_FULL}"
  echo "  GCP_SERVICE_ACCOUNT            = ${GCP_SA_EMAIL}"
  echo "  GCS_BUCKET                     = ${GCS_BUCKET}"
  echo ""
  read -rp "Proceed with setting these secrets? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    gh secret set AZURE_CLIENT_ID       --body "$AZURE_CLIENT_ID"       --repo "$GITHUB_REPO"
    gh secret set AZURE_TENANT_ID       --body "$AZURE_TENANT_ID"       --repo "$GITHUB_REPO"
    gh secret set AZURE_SUBSCRIPTION_ID --body "$AZURE_SUBSCRIPTION_ID" --repo "$GITHUB_REPO"
    gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "$GCP_WIF_PROVIDER_FULL" --repo "$GITHUB_REPO"
    gh secret set GCP_SERVICE_ACCOUNT   --body "$GCP_SA_EMAIL"          --repo "$GITHUB_REPO"
    gh secret set GCS_BUCKET            --body "$GCS_BUCKET"            --repo "$GITHUB_REPO"
    ok "All GitHub secrets set on ${GITHUB_REPO}"
  else
    warn "Skipped setting GitHub secrets. You can set them manually or re-run with --github"
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "============================================="
echo "  Setup complete!"
echo "============================================="
echo ""
echo "  Azure App:     $AZURE_APP_NAME ($AZURE_CLIENT_ID)"
echo "  GCP SA:        $GCP_SA_EMAIL"
echo "  WIF Provider:  $GCP_WIF_PROVIDER_FULL"
echo "  Variables:      $ENV_FILE"
echo ""
echo "  Next steps:"
echo "    1. cd terraform && terraform init -backend-config=backend.conf && terraform plan"
if [[ "$SETUP_GITHUB" == false ]]; then
  echo "    2. To set GitHub secrets later: ./init.sh --github"
fi
echo ""
