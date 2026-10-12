// Infrastructure for the G-Cubed model on Microsoft Foundry (hosted agent).
// Deployed at resource-group scope by the GitHub Actions workflow (idempotent).
//
//   Azure Container Registry (Basic)   - stores the G-Cubed API container image
//   Foundry resource (AIServices)      - Microsoft Foundry account, no model deployments
//   Foundry project                    - hosts the 'gcubed-model' hosted agent
//   AcrPull role assignments           - lets Foundry pull the image from ACR

@description('Azure region. Must support Foundry hosted agents (e.g. australiaeast).')
param location string = resourceGroup().location

@description('Short lowercase prefix for resource names.')
@maxLength(12)
param namePrefix string = 'gcubed'

@description('Foundry project name.')
param projectName string = 'gcubed-project'

var suffix = uniqueString(resourceGroup().id)
var acrName = toLower('${namePrefix}acr${suffix}')
var foundryName = toLower('${namePrefix}-foundry-${suffix}')
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'G-Cubed model'
    description: 'Hosts the G-Cubed macroeconomic model as a containerised hosted agent.'
  }
}

resource projectAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, project.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource accountAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, foundry.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: foundry.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output foundryName string = foundry.name
output projectName string = project.name
output projectEndpoint string = 'https://${foundryName}.services.ai.azure.com/api/projects/${projectName}'
