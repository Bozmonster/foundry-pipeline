#!/usr/bin/env bash
# Remove all Azure resources for this pipeline (the resource group and everything in it).
# GitHub repositories are left alone; delete them on GitHub if you no longer need them.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_az_login
ask AZURE_RESOURCE_GROUP "Resource group to DELETE" "rg-gcubed-foundry"
az resource list -g "$AZURE_RESOURCE_GROUP" --query "[].{name:name,type:type}" -o table
read -r -p "Type the resource group name to confirm deletion: " c
[ "$c" = "$AZURE_RESOURCE_GROUP" ] || die "Not confirmed"
run az group delete -n "$AZURE_RESOURCE_GROUP" --yes --no-wait
ok "Deletion started. Foundry resources are soft-deleted; purge with:"
echo "  az cognitiveservices account list-deleted -o table"
echo "  az cognitiveservices account purge -g $AZURE_RESOURCE_GROUP -n <foundry-name> -l <location>"
