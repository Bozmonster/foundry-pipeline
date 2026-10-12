<#
.SYNOPSIS
  One-time Azure setup so GitHub Actions can deploy G-Cubed to Microsoft Foundry.

.DESCRIPTION
  Creates a resource group, an Entra app registration with a GitHub OIDC
  federated credential (no secrets stored anywhere), grants it the roles it
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
  [string]$AppName = "github-foundry-pipeline-oidc",
  [string]$Subscription = ""
)
$ErrorActionPreference = "Stop"

if ($Subscription) { az account set --subscription $Subscription | Out-Null }
$account = az account show | ConvertFrom-Json
$subId = $account.id; $tenantId = $account.tenantId
Write-Host "Subscription: $($account.name) ($subId)"

Write-Host "Registering resource providers..."
foreach ($p in "Microsoft.CognitiveServices", "Microsoft.ContainerRegistry") {
  az provider register --namespace $p | Out-Null
}

Write-Host "Creating resource group $ResourceGroup in $Location..."
$rgId = (az group create --name $ResourceGroup --location $Location | ConvertFrom-Json).id

Write-Host "Creating app registration $AppName..."
$appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) { $appId = az ad app create --display-name $AppName --query appId -o tsv }
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) { $spId = az ad sp create --id $appId --query id -o tsv }

Write-Host "Adding GitHub OIDC federated credentials..."
$subjects = @{
  "gh-env-$Environment" = "repo:${Repo}:environment:$Environment"
  "gh-branch-main"      = "repo:${Repo}:ref:refs/heads/main"
}
$existing = az ad app federated-credential list --id $appId --query "[].name" -o tsv
foreach ($name in $subjects.Keys) {
  if ($existing -notcontains $name) {
    $file = New-TemporaryFile
    @{ name = $name; issuer = "https://token.actions.githubusercontent.com";
       subject = $subjects[$name]; audiences = @("api://AzureADTokenExchange") } |
      ConvertTo-Json | Set-Content $file
    az ad app federated-credential create --id $appId --parameters "@$file" | Out-Null
    Remove-Item $file
  }
}

Write-Host "Assigning roles on $ResourceGroup..."
$roles = @{
  "Contributor"                                 = "b24988ac-6180-42a0-ab88-20f7382dd24c"  # create ACR/Foundry, push images
  "Role Based Access Control Administrator"     = "f58310d9-a9f6-439a-9e8d-f62e7b41a168"  # Bicep assigns AcrPull to Foundry
  "Azure AI Project Manager"                    = "eadc314b-1a2d-4efa-be10-5d325db5065e"  # create hosted agents
  "Azure AI User"                               = "53ca6127-db72-4b80-b1b0-d745d6d5456d"  # invoke the agent (smoke test)
}
foreach ($r in $roles.GetEnumerator()) {
  az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
    --role $r.Value --scope $rgId --only-show-errors | Out-Null
  Write-Host "  pipeline identity -> $($r.Key)"
}

$ErrorActionPreference = "Continue"
try { $me = az ad signed-in-user show --query id -o tsv 2>$null } catch { $me = $null }
if ($me) {
  az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role $roles["Azure AI User"] --scope $rgId --only-show-errors | Out-Null
  Write-Host "  you -> Azure AI User (to call the API)"
} else {
  Write-Host "  (skipped granting you Azure AI User - Graph lookup blocked; add it in the portal if you want to call the API yourself)"
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
