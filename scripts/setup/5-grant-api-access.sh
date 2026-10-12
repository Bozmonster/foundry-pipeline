#!/usr/bin/env bash
# Step 5 - Give a person (or app) permission to call the G-Cubed API on Foundry.
# Grants "Azure AI User" on the resource group. Callers authenticate with Entra ID.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

bold "Step 5 of 5 - Grant API access"
need_az_login
ask AZURE_RESOURCE_GROUP "Resource group" "rg-gcubed-foundry"
RG_ID=$(az group show -n "$AZURE_RESOURCE_GROUP" --query id -o tsv)

echo "Who should get access? Enter a user email (UPN), or an object id."
echo "(Leave blank to grant yourself; in tenants with security defaults, object ids avoid Graph lookups.)"
read -r -p "User email or object id: " WHO
if [ -z "$WHO" ]; then
  # your object id from the access token (no Graph call needed)
  WHO=$(az account get-access-token --query accessToken -o tsv | cut -d. -f2 | python3 -c \
    'import base64,json,sys; s=sys.stdin.read().strip(); s+="="*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s))["oid"])')
fi
if [[ "$WHO" =~ ^[0-9a-f-]{36}$ ]]; then
  run az role assignment create --assignee-object-id "$WHO" --assignee-principal-type User \
    --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope "$RG_ID" -o none
else
  run az role assignment create --assignee "$WHO" \
    --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope "$RG_ID" -o none
fi
ok "$WHO can now call the API (allow a few minutes for the role to apply)"
echo "Try it:  PROJECT_ENDPOINT=${PROJECT_ENDPOINT:-<project endpoint>} bash scripts/invoke-report.sh"
