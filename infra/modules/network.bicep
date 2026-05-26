param location string
param nameBase string

// Overlay mode: pods get IPs from podCidr (100.64.0.0/10 by default), NOT from this subnet.
// Nodes still need VNet IPs, but only 1 IP per node — a /24 comfortably holds 5–20 nodes.
// Old subnet mode consumed 1 IP per node PLUS up to 30 IPs per node for pods, so a /22 was
// needed for safety. With Overlay, /24 (~250 host IPs) is generous for a lab.
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
          // /24 = 251 usable IPs — sufficient for nodes in Overlay mode.
          // Previously /22 was needed to accommodate per-pod subnet IPs.
          addressPrefix: '10.40.0.0/24'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output aksSubnetId string = '${vnet.id}/subnets/snet-aks'
