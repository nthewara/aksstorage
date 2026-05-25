param location string
param nameBase string

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${nameBase}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.40.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: '10.40.0.0/22'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output aksSubnetId string = '${vnet.id}/subnets/snet-aks'
