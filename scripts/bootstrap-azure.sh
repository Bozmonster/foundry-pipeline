#!/usr/bin/env bash
# One-time Azure setup for the G-Cubed Foundry pipeline (bash / Azure Cloud Shell).
# Creates: resource group, user-assigned managed identity with GitHub OIDC federated
# credentials (no secrets), role assignments for the pipeline and for you.
set -uo pipefail
REPO="${REPO:-Bozmonster/foundry-pipeline}"
RG="${RG:-rg-gcubed-foundry}"
LOC="${LOC:-australiaeast}"
ID_NAME="${ID_NAME:-id-github-foundry-pipeline}"
ENV_NAME="${ENV_NAME:-azure}"
# GitHub may send ID-based OIDC subjects (repo:<owner>@<ownerId>/<repo>@<repoId>:...).
# The workflow error message shows the exact value; both formats are registered.
REPO_IDS="${REPO_IDS:-Bozmonster@5046023/foundry-pipeline@1415161671}"

for p in Microsoft.CognitiveServices Microsoft.ContainerRegistry Microsoft.ManagedIdentity; do
  az provider register --namespace "$p" -o none
done
RG_ID=$(az group create -n "$RG" -l "$LOC" --query id -o tsv)
read -r CLIENT_ID PRINCIPAL_ID < <(az identity create -g "$RG" -n "$ID_NAME" -l "$LOC" --query "[clientId,principalId]" -o tsv | tr '\n' ' ')
echo "identity clientId=$CLIENT_ID principalId=$PRINCIPAL_ID"

for pair in "gh-env-$ENV_NAME=repo:$REPO:environment:$ENV_NAME" "gh-branch-main=repo:$REPO:ref:refs/heads/main" \
            "gh-id-env-$ENV_NAME=repo:$REPO_IDS:environment:$ENV_NAME" "gh-id-branch-main=repo:$REPO_IDS:ref:refs/heads/main"; do
  az identity federated-credential create -g "$RG" --identity-name "$ID_NAME" --name "${pair%%=*}" \
    --issuer https://token.actions.githubusercontent.com --subject "${pair#*=}" \
    --audiences api://AzureADTokenExchange -o none && echo "federated: ${pair#*=}"
done

# Contributor, RBAC Administrator, Azure AI Project Manager, Azure AI User
for role in b24988ac-6180-42a0-ab88-20f7382dd24c f58310d9-a9f6-439a-9e8d-f62e7b41a168 \
            eadc314b-1a2d-4efa-be10-5d325db5065e 53ca6127-db72-4b80-b1b0-d745d6d5456d; do
  for i in 1 2 3 4 5 6; do
    az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$RG_ID" -o none 2>/dev/null && { echo "pipeline role $role ok"; break; }
    sleep 10
  done
done

ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [ -n "$ME" ]; then
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope "$RG_ID" -o none && echo "you -> Azure AI User"
fi

echo
echo "GitHub repository variables:"
echo "AZURE_CLIENT_ID=$CLIENT_ID"
echo "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)"
echo "AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)"
echo "AZURE_RESOURCE_GROUP=$RG"
echo "AZURE_LOCATION=$LOC"
