#!/usr/bin/env bash
# Step 3 - Create everything in Azure, interactively:
#   resource group, managed identity for GitHub Actions (OIDC, no secrets), federated credentials,
#   role assignments, Azure Container Registry, Microsoft Foundry resource + project, AcrPull roles,
#   your own API access, and the GitHub repository variables the workflow reads.
# Run in Azure Cloud Shell (bash) from a clone of the pipeline repo.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

bold "Step 3 of 5 - Azure resources"
need_az_login; need python3

# Regions that support Foundry hosted agents
HOSTED_AGENT_REGIONS="australiaeast brazilsouth canadacentral canadaeast centralus eastus eastus2 francecentral germanywestcentral italynorth japaneast japanwest koreacentral northcentralus norwayeast polandcentral southafricanorth southcentralus southindia southeastasia spaincentral swedencentral switzerlandnorth switzerlandwest uaenorth uksouth ukwest westcentralus westeurope westus westus3"

info "Subscriptions you can use:"
az account list --query "[?state=='Enabled'].{name:name, id:id, default:isDefault}" -o table
ask AZURE_SUBSCRIPTION_ID "Subscription id" "$(az account show --query id -o tsv)"
run az account set --subscription "$AZURE_SUBSCRIPTION_ID"
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv); save AZURE_TENANT_ID

ask AZURE_LOCATION "Region (must support Foundry hosted agents)" "australiaeast"
[[ " $HOSTED_AGENT_REGIONS " == *" $AZURE_LOCATION "* ]] || warn "$AZURE_LOCATION is not in the known hosted-agent region list"
ask AZURE_RESOURCE_GROUP "Resource group name" "rg-gcubed-foundry"
ask NAME_PREFIX "Short lowercase prefix for resource names (max 12 chars)" "gcubed"
ask IDENTITY_NAME "Managed identity used by GitHub Actions" "id-github-foundry-pipeline"
ask PIPELINE_REPO "GitHub pipeline repository (owner/name)" "Bozmonster/foundry-pipeline"
ask GITHUB_ENVIRONMENT "GitHub environment name used by the workflow" "azure"

bold "About to create/update in subscription $(az account show --query name -o tsv):"
cat <<EOF
  Resource group     $AZURE_RESOURCE_GROUP ($AZURE_LOCATION)
  Managed identity   $IDENTITY_NAME  (+ GitHub OIDC trust for $PIPELINE_REPO)
  Role assignments   Contributor, RBAC Administrator, Azure AI Project Manager, Azure AI User (on the resource group)
  Container registry ${NAME_PREFIX}acr<unique>  (Basic, ~US\$5/month)
  Foundry resource   ${NAME_PREFIX}-foundry-<unique> + project gcubed-project
EOF
confirm "Continue?" || die "Cancelled"

info "Registering resource providers (first time only, can take a minute)"
for p in Microsoft.CognitiveServices Microsoft.ContainerRegistry Microsoft.ManagedIdentity; do
  run az provider register --namespace "$p" --wait -o none
done

info "Resource group"
RG_ID=$(az group create -n "$AZURE_RESOURCE_GROUP" -l "$AZURE_LOCATION" --query id -o tsv); ok "$RG_ID"

info "Managed identity for GitHub Actions"
IDENTITY=$(az identity create -g "$AZURE_RESOURCE_GROUP" -n "$IDENTITY_NAME" -l "$AZURE_LOCATION" \
  --query "[clientId,principalId]" -o tsv)
AZURE_CLIENT_ID=$(sed -n 1p <<<"$IDENTITY"); PRINCIPAL_ID=$(sed -n 2p <<<"$IDENTITY")
[ -n "$PRINCIPAL_ID" ] || die "Managed identity creation failed"
save AZURE_CLIENT_ID; ok "clientId $AZURE_CLIENT_ID"

info "Federated credentials (trust GitHub's OIDC tokens for $PIPELINE_REPO)"
SUBJECT_PREFIXES=("repo:$PIPELINE_REPO")
# GitHub may also issue ID-based subjects: repo:<owner>@<ownerId>/<repo>@<repoId>
IDS=$(curl -fsSL "https://api.github.com/repos/$PIPELINE_REPO" 2>/dev/null | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["owner"]["login"]+"@"+str(d["owner"]["id"])+"/"+d["name"]+"@"+str(d["id"]))' 2>/dev/null || true)
if [ -z "$IDS" ] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  IDS=$(gh api "repos/$PIPELINE_REPO" --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' 2>/dev/null || true)
fi
[ -n "$IDS" ] && SUBJECT_PREFIXES+=("repo:$IDS") || warn "Could not look up repo IDs; only the classic subject format is trusted"
existing=$(az identity federated-credential list -g "$AZURE_RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" --query "[].subject" -o tsv)
n=0
for prefix in "${SUBJECT_PREFIXES[@]}"; do
  for suffix in "environment:$GITHUB_ENVIRONMENT" "ref:refs/heads/main"; do
    n=$((n+1)); subject="$prefix:$suffix"
    if grep -qxF "$subject" <<<"$existing"; then ok "exists: $subject"; continue; fi
    run az identity federated-credential create -g "$AZURE_RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" \
      --name "github-$n-$(date +%s)" --issuer https://token.actions.githubusercontent.com \
      --subject "$subject" --audiences api://AzureADTokenExchange -o none
    ok "trusts: $subject"
  done
done

info "Role assignments for the pipeline identity (scope: resource group only)"
declare -A ROLES=(
  [Contributor]=b24988ac-6180-42a0-ab88-20f7382dd24c
  ["Role Based Access Control Administrator"]=f58310d9-a9f6-439a-9e8d-f62e7b41a168
  ["Azure AI Project Manager"]=eadc314b-1a2d-4efa-be10-5d325db5065e
  ["Azure AI User"]=53ca6127-db72-4b80-b1b0-d745d6d5456d
)
for role in "${!ROLES[@]}"; do
  for i in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
         --role "${ROLES[$role]}" --scope "$RG_ID" -o none 2>/dev/null; then ok "$role"; break; fi
    [ "$i" = 6 ] && warn "Could not assign $role"; sleep 10   # new identities take a moment to replicate
  done
done

info "Container registry + Foundry resource + project (infra/main.bicep)"
OUT=$(az deployment group create -g "$AZURE_RESOURCE_GROUP" -n gcubed-infra \
  --template-file "$SETUP_ROOT/infra/main.bicep" \
  --parameters location="$AZURE_LOCATION" namePrefix="$NAME_PREFIX" \
  --query properties.outputs -o json)
PROJECT_ENDPOINT=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["projectEndpoint"]["value"])' <<<"$OUT"); save PROJECT_ENDPOINT
ACR_NAME=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["acrName"]["value"])' <<<"$OUT"); save ACR_NAME
ok "ACR $ACR_NAME"; ok "Foundry project $PROJECT_ENDPOINT"

info "Your own access to call the API (Azure AI User)"
ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [ -n "$ME" ]; then
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope "$RG_ID" -o none && ok "you ($ME)"
else
  warn "Could not look up your user (Graph blocked). Use scripts/setup/5-grant-api-access.sh or the portal."
fi

info "GitHub repository variables"
VARS=(AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_LOCATION)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  for v in "${VARS[@]}"; do run gh variable set "$v" --repo "$PIPELINE_REPO" --body "${!v}"; done
  ok "Variables set on $PIPELINE_REPO"
else
  warn "GitHub CLI not logged in. Add these in GitHub > Settings > Secrets and variables > Actions > Variables:"
  for v in "${VARS[@]}"; do echo "    $v = ${!v}"; done
fi

bold "Azure setup complete. Values saved to $SETUP_ENV"
echo "Next: bash scripts/setup/4-run-pipeline.sh"
