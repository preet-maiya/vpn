@description('Region')
param location string

param storageName string
param planName string
param functionAppName string
param workspaceId string
param vmName string
param resourceGroupName string
param publicIpName string

// Storage account
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// Storage key
var storageKey = storage.listKeys().keys[0].value

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionAppName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
  }
}

// Consumption Plan
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  kind: 'functionapp,linux'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    // Required to mark the plan as Linux; without this the plan is treated as Windows and rejects linuxFxVersion
    reserved: true
  }
}

// Function App
resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    reserved: true

    siteConfig: {
      // Linux runtime identifier must use exact token from list-runtimes (case-sensitive)
      linuxFxVersion: 'PYTHON|3.10'

      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'RESOURCE_GROUP_NAME'
          value: resourceGroupName
        }
        {
          name: 'VM_NAME'
          value: vmName
        }
        {
          name: 'PUBLIC_IP_NAME'
          value: publicIpName
        }
        {
          name: 'LOCATION'
          value: location
        }
        {
          name: 'MAX_IDLE_SECONDS'
          value: string(8 * 3600)
        }
      ]
    }
  }
}

output functionHostname string = func.properties.defaultHostName
output functionAppId string = func.id
output principalId string = func.identity.principalId
