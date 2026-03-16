// Resource-group-scope deployment: network, VM, functions, monitoring, budget role assignments
// This file is invoked from main.bicep at subscription scope.
targetScope = 'resourceGroup'

@description('Azure region for resources')
param location string

@description('Tailscale auth key (server-scoped, reusable)')
@secure()
param tailscaleAuthKey string

@description('Optional SSH public key for admin login')
param sshPublicKey string = ''

@description('VM priority. Spot is cheaper but may fail; set to Regular to force pay-as-you-go.')
@allowed([
  'Spot'
  'Regular'
])
param vmPriority string = 'Regular'

@description('VM size for the exit node')
param vmSize string = 'Standard_B2s_v2'

var vnetCidr = '10.10.0.0/16'
var subnetCidr = '10.10.1.0/24'
var vmName = 'ts-exit'
var publicIpName = 'ts-exit-pip'
// include location to avoid clashes when redeploying same RG in another region
var nameSalt = uniqueString(subscription().id, resourceGroup().name, location)
var vnetName = 'vpn-vnet-${nameSalt}'
var subnetName = 'vpn-subnet-${nameSalt}'
var nsgName = 'vpn-nsg-${nameSalt}'
var workspaceName = 'ts-logs-${nameSalt}'
var functionAppName = 'ts-exit-func-${nameSalt}'
var storageName = toLower(replace('stts${nameSalt}','-',''))
var planName = 'ts-functions-plan-${nameSalt}'

// Load and inject auth key into cloud-init (path relative to this file)
var cloudInitBase = loadTextContent('../../scripts/cloud-init.sh')
var cloudInit = replace(cloudInitBase, '__TAILSCALE_AUTH_KEY__', tailscaleAuthKey)

resource logws 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: 30
    features: {
      searchVersion: 2
    }
  }
  // bicep:disable-next-line BCP187
  sku: {
    name: 'PerGB2018'
  }
}

module network 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetCidr: vnetCidr
    subnetCidr: subnetCidr
    allowSsh: (sshPublicKey != '')
    vnetName: vnetName
    subnetName: subnetName
    nsgName: nsgName
  }
}

module vm 'vm.bicep' = {
  name: 'vm'
  params: {
    location: location
    vmName: vmName
    vmSize: vmSize
    vmPriority: vmPriority
    subnetId: network.outputs.subnetId
    publicIpName: publicIpName
    adminSshKey: sshPublicKey
    cloudInit: cloudInit
  }
}

module functions 'functions.bicep' = {
  name: 'functions'
  params: {
    location: location
    storageName: storageName
    planName: planName
    functionAppName: functionAppName
    workspaceId: logws.id
    vmName: vmName
    resourceGroupName: resourceGroup().name
    publicIpName: publicIpName
  }
}

// Diagnostic settings for VM and Function App
resource vmRes 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

// resource vmDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
//   name: 'vm-diagnostics'
//   scope: vmRes
//   dependsOn: [vm]
//   properties: {
//     workspaceId: logws.id
//     logs: [
//       {
//         category: 'GuestOS'
//         enabled: true
//       }
//       {
//         category: 'BootDiagnostics'
//         enabled: true
//       }
//     ]
//     metrics: [
//       {
//         category: 'AllMetrics'
//         enabled: true
//       }
//     ]
//   }
// }

// resource funcApp 'Microsoft.Web/sites@2023-12-01' existing = {
//   name: functionAppName
// }

// resource funcDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
//   name: 'functions-diagnostics'
//   scope: funcApp
//   dependsOn: [functions]
//   properties: {
//     workspaceId: logws.id
//     logs: [
//       {
//         category: 'FunctionAppLogs'
//         enabled: true
//       }
//       {
//         category: 'AppServicePlatformLogs'
//         enabled: true
//       }
//     ]
//     metrics: [
//       {
//         category: 'AllMetrics'
//         enabled: true
//       }
//     ]
//   }
// }

// Grant managed identity permissions to control VM and public IP
resource roleVm 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'vm-contrib')
  properties: {
    // Correct GUID for built-in "Virtual Machine Contributor" in this subscription
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: functions.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource roleNet 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'net-contrib')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7') // Network Contributor
    principalId: functions.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

output publicIp string = vm.outputs.publicIp
output vmNameOut string = vm.outputs.vmName
output tailscaleHostname string = '${vm.outputs.vmName}-exit'
output startFunctionUrl string = 'https://${functions.outputs.functionHostname}/api/start-vm'
