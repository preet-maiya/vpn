@description('Deployment region')
param location string
@description('VNet CIDR')
param vnetCidr string
@description('Subnet CIDR')
param subnetCidr string
@description('Allow SSH from Internet')
param allowSsh bool = false

@description('NSG name')
param nsgName string = 'vpn-nsg'

@description('VNet name')
param vnetName string = 'vpn-vnet'

@description('Subnet name')
param subnetName string = 'vpn-subnet'

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetCidr]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetCidr
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: concat(
      allowSsh ? [
        {
          name: 'Allow-SSH'
          properties: {
            priority: 1000
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
          }
        }
      ] : [],
      [
        {
          name: 'Allow-Tailscale'
          properties: {
            priority: 1001
            direction: 'Inbound'
            access: 'Allow'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
            description: 'Tailscale uses UDP/41641 and HTTPS; keep open for DERP/TS'
          }
        }
      ]
    )
  }
}

output subnetId string = vnet.properties.subnets[0].id
