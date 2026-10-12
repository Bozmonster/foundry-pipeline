<#
.SYNOPSIS
  One-time Azure setup so GitHub Actions can deploy G-Cubed to Microsoft Foundry.

.DESCRIPTION
  Creates a resource group, a user-assigned managed identity with GitHub OIDC
  federated credentials (no secrets stored anywhere), grants it the roles it
  needs on the resource group, gives you permission to call the API, and
  (if the GitHub CLI is available) sets the repository variables the workflow reads.

  Run from PowerShell with the Azure CLI logged in (az login).

.EXAMPLE
  ./scripts/bootstrap-azure.ps1 -Repo Bozmonster/foundry-pipeline
#>
param(
  [string]$Repo = "Bozmonster/foundry-pipeline",
  [string]$ResourceGroup = "rg-gcubed-foundry",
  [string]$Location = "australiaeast",
  [string]$Environment = "azure",
  [string]$IdentityName = "id-github-foundry-pipeline",
  [string]$Subscription = ""
)
$ErrorActionPreference = "Continue"

if ($Subscription) { az account set --subscription $Subscription | Out-Null }
$account = az account show | ConvertFrom-Json
$subId = $account.id; $tenantId = $account.tenantId
Write-Host "Subscription: $($account.name) ($subId)"

Write-Host "Registering resource providers..."
foreach ($p in "Microsoft.CognitiveServices", "Microsoft.ContainerRegistry", "Microsoft.ManagedIdentity") {
  az provider register --namespace $p | Out-Null
}

Write-Host "Creating resource group $ResourceGroup in $Location..."
$rgId = (az group create --name $ResourceGroup --location $Location | ConvertFrom-Json).id

# A user-assigned managed identity + federated credential gives GitHub Actions
# secretless OIDC login using only Azure Resource Manager (no Entra app registration).
Write-Host "Creating managed identity $IdentityName..."
$id = az identity create --resource-group $ResourceGroup --name $IdentityName --location $Location -o json | ConvertFrom-Json
$appId = $id.clientId; $spId = $id.principalId
Write-Host "  clientId=$appId principalId=$spId"

Write-Host "Adding GitHub OIDC federated credentials..."
$subjects = [ordered]@{
  "gh-env-$Environment" = "repo:${Repo}:environment:$Environment"
  "gh-branch-main"      = "repo:${Repo}:ref:refs/heads/main"
}
foreach ($name in $subjects.Keys) {
  az identity federated-credential create --resource-group $ResourceGroup --identity-name $IdentityName `
    --name $name --issuer "https://token.actions.githubusercontent.com" `
    --subject $subjects[$name] --audiences "api://AzureADTokenExchange" --only-show-errors | Out-Null
  Write-Host "  $name -> $($subjects[$name]) (exit $LASTEXITCODE)"
}

Write-Host "Assigning roles on $ResourceGroup..."
$roles = [ordered]@{
  "Contributor"                             = "b24988ac-6180-42a0-ab88-20f7382dd24c"  # create ACR/Foundry, push images
  "Role Based Access Control Administrator" = "f58310d9-a9f6-439a-9e8d-f62e7b41a168"  # Bicep assigns AcrPull to Foundry
  "Azure AI Project Manager"                = "eadc314b-1a2d-4efa-be10-5d325db5065e"  # create hosted agents
  "Azure AI User"                           = "53ca6127-db72-4b80-b1b0-d745d6d5456d"  # invoke the agent (smoke test)
}
foreach ($r in $roles.GetEnumerator()) {
  for ($try = 1; $try -le 6; $try++) {
    az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
      --role $r.Value --scope $rgId --only-show-errors | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 10   # new identities take a moment to replicate
  }
  Write-Host "  pipeline identity -> $($r.Key) (exit $LASTEXITCODE)"
}

# Your own object id, read from the ARM access token (avoids Graph, which security defaults may block)
$tok = az account get-access-token --query accessToken -o tsv
$payload = $tok.Split(".")[1].Replace("-", "+").Replace("_", "/")
switch ($payload.Length % 4) { 2 { $payload += "==" } 3 { $payload += "=" } }
$me = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json).oid
if ($me) {
  az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role $roles["Azure AI User"] --scope $rgId --only-show-errors | Out-Null
  Write-Host "  you ($me) -> Azure AI User, so you can call the API (exit $LASTEXITCODE)"
}

$vars = [ordered]@{
  AZURE_CLIENT_ID = $appId; AZURE_TENANT_ID = $tenantId; AZURE_SUBSCRIPTION_ID = $subId
  AZURE_RESOURCE_GROUP = $ResourceGroup; AZURE_LOCATION = $Location
}
$vars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content (Join-Path $PSScriptRoot "..\_local\azure-vars.txt")
if (Get-Command gh -ErrorAction SilentlyContinue) {
  foreach ($k in $vars.Keys) { gh variable set $k --repo $Repo --body $vars[$k] }
  Write-Host "GitHub repository variables set on $Repo"
} else {
  Write-Host "`nAdd these as GitHub repository variables (Settings > Secrets and variables > Actions > Variables):"
  $vars.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" }
}
Write-Host "`nDone. Push to main or run the 'Deploy G-Cubed to Microsoft Foundry' workflow."
