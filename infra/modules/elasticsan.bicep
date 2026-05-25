// Optional Elastic SAN module — toggled by deployElasticSan param in main.bicep.
// Creates a minimal ESAN (1 TiB base capacity) with one volume group, then
// grants the AKS kubelet identity the "Elastic SAN Volume Group Owner" role
// so ACStor can provision volumes dynamically.
//
// Deploy with:
//   az deployment group create -g $RG -f infra/main.bicep \
//     -p @infra/main.parameters.json deployElasticSan=true
//
// After deploy, enable ESAN storage type on the cluster:
//   az aks update -g $RG -n $CLUSTER \
//     --enable-azure-container-storage elasticSan \
//     --elastic-san-resource-id <esanId from outputs>
// See docs/ELASTIC-SAN.md for the full walkthrough.

param location string
param nameBase string
param kubeletIdentityObjectId string

@description('Base capacity in TiB. Each TiB adds 5,000 IOPS + 200 MB/s throughput.')
@minValue(1)
@maxValue(100)
param baseSizeTiB int = 1

@description('Extended (capacity-only) TiB on top of base. Does not add IOPS/throughput.')
@minValue(0)
param extendedSizeTiB int = 0

var esanName = 'esan-${nameBase}'
var volumeGroupName = 'vg-acstor'

// Elastic SAN requires at least one availability zone in australiaeast.
resource esan 'Microsoft.ElasticSan/elasticSans@2023-01-01' = {
  name: esanName
  location: location
  properties: {
    baseSizeTiB: baseSizeTiB
    extendedCapacitySizeTiB: extendedSizeTiB
    availabilityZones: ['1']
    sku: {
      name: 'Premium_LRS'
      tier: 'Premium'
    }
  }
}

resource volumeGroup 'Microsoft.ElasticSan/elasticSans/volumeGroups@2023-01-01' = {
  parent: esan
  name: volumeGroupName
  properties: {
    protocolType: 'Iscsi'
    encryption: 'EncryptionAtRestWithPlatformKey'
  }
}

// "Elastic SAN Volume Group Owner" — allows ACStor to create/delete volumes in this VG.
// Role definition ID: e1baa0c0-fedb-4057-8c66-6b5a47b0de32
resource esanVgOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(volumeGroup.id, kubeletIdentityObjectId, 'esan-vg-owner')
  scope: volumeGroup
  properties: {
    principalId: kubeletIdentityObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'e1baa0c0-fedb-4057-8c66-6b5a47b0de32'
    )
  }
}

// NOTE: The "Azure Container Storage Operator" role at subscription scope must be
// assigned separately (subscription-scoped resources require their own module in Bicep).
// Run this after deploying:
//   AKS_MI=$(az aks show -g $RG -n $CLUSTER --query identityProfile.kubeletidentity.objectId -o tsv)
//   az role assignment create --assignee $AKS_MI \
//     --role "Azure Container Storage Operator" \
//     --scope "/subscriptions/<sub-id>"
// Or use the infra/modules/acstor-operator-rbac.bicep module (subscription-scoped).

output esanId string = esan.id
output esanName string = esan.name
output volumeGroupName string = volumeGroup.name
output volumeGroupId string = volumeGroup.id
