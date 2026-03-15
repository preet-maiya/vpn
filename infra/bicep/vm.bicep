@description('Region')
param location string

@description('VM name')
param vmName string

@description('VM size')
param vmSize string

@description('VM priority')
@allowed([
  'Spot'
  'Regular'
])
param vmPriority string = 'Regular'

@description('Subnet resource ID')
param subnetId string

@description('Public IP name')
param publicIpName string

@description('Admin SSH public key')
@minLength(30)
param adminSshKey string

@description('Admin username')
param adminUsername string = 'azureuser'

@description('cloud-init user-data content')
param cloudInit string

var nicName = '${vmName}-nic'

var imageRef = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy'
  sku: '22_04-lts'
  version: 'latest'
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 15
    dnsSettings: {
      domainNameLabel: toLower('${vmName}${uniqueString(resourceGroup().id)}')
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location

  properties: union(
    vmPriority == 'Spot'
      ? {
          priority: 'Spot'
          evictionPolicy: 'Deallocate'
        }
      : {
          priority: 'Regular'
        },
    {
      hardwareProfile: {
        vmSize: vmSize
      }

      osProfile: {
        computerName: vmName
        adminUsername: adminUsername
        customData: base64(cloudInit)

        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshKey
              }
            ]
          }
        }
      }

      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
        imageReference: imageRef
      }

      networkProfile: {
        networkInterfaces: [
          {
            id: nic.id
          }
        ]
      }

      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
    }
  )

  identity: {
    type: 'SystemAssigned'
  }
}

output publicIp string = pip.properties.ipAddress
output publicDns string = pip.properties.dnsSettings.fqdn
output vmName string = vm.name
output vmId string = vm.id
