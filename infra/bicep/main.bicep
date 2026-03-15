// Subscription-scope entry point: creates resource group and delegates RG resources to module.
targetScope = 'subscription'

@description('Name of resource group to create/deploy into')
param resourceGroupName string

@description('Azure region for resources')
param location string = 'centralindia'

@description('Tailscale auth key (server-scoped, reusable)')
@secure()
param tailscaleAuthKey string

@description('Optional SSH public key for admin login')
param sshPublicKey string = ''

@description('Budget start date (ISO 8601). Defaults to now.')
param budgetStartDate string = utcNow()

@description('VM priority. Spot is cheaper but may fail; set to Regular to force pay-as-you-go.')
@allowed([
  'Spot'
  'Regular'
])
param vmPriority string = 'Regular'

// Create or reuse the resource group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// Deploy all resource-group-scoped resources via module
module rgResources 'rg.bicep' = {
  name: 'rg-resources'
  scope: rg
  params: {
    location: location
    tailscaleAuthKey: tailscaleAuthKey
    sshPublicKey: sshPublicKey
    vmPriority: vmPriority
  }
}

output publicIp string = rgResources.outputs.publicIp
output vmNameOut string = rgResources.outputs.vmNameOut
output tailscaleHostname string = rgResources.outputs.tailscaleHostname
output startFunctionUrl string = rgResources.outputs.startFunctionUrl

// Budget at subscription scope ($10/month)
resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: 'ts-exit-budget'
  scope: subscription()
  properties: {
    category: 'Cost'
    amount: 10
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
      endDate: dateTimeAdd(budgetStartDate, 'P1Y')
    }
    notifications: {
      actual_greater_than_80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: []
        contactRoles: [
          'Owner'
        ]
      }
    }
  }
}
