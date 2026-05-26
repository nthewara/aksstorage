// aksstorage — Azure Container Storage v2.1 lab
// Bicep entry point. Composes: VNet, Log Analytics, AKS (system + storage pools),
// and optionally an Elastic SAN module.
//
// Deploy:
//   az deployment group create -g $RG -f infra/main.bicep -p @infra/main.parameters.json

@description('Location for all resources.')
param location string = 'australiaeast'

@description('Short prefix for resource names. Lowercase, 3-8 chars.')
@minLength(3)
@maxLength(8)
param prefix string = 'acsl'

@description('Suffix appended to resource names (kept short for uniqueness).')
param suffix string = uniqueString(resourceGroup().id)

@description('Kubernetes version. 1.34+ recommended for ACS v2.1 (1.31 is now LTS-only — Premium tier required).')
param kubernetesVersion string = '1.34'

@description('System node pool VM size. Small — no storage role.')
param systemVmSize string = 'Standard_D4s_v5'

@description('System node count.')
param systemNodeCount int = 2

@description('Storage pool VM size. Must support local NVMe (Lsv3 / Lasv3).')
param storagepoolVmSize string = 'Standard_L8s_v3'

@description('Storage pool node count (3 = one per AZ).')
param storagepoolNodeCount int = 3

@description('Object ID of the principal (user / SP) that will get cluster-admin via AAD. Optional.')
param adminAadObjectId string = ''

@description('AKS cluster tier — Standard (recommended) gives 99.9% API server SLA.')
param clusterTier string = 'Standard'

@description('Pod CIDR for Azure CNI Overlay. Not routed in the VNet. Default 100.64.0.0/10 gives ~4M pod IPs.')
param podCidr string = '100.64.0.0/10'

@description('Restrict API server access to these CIDRs. Empty array = unrestricted (dev default).')
param apiServerAuthorizedIPRanges array = []

@description('Deploy the optional Elastic SAN module. Set true to create ESAN + RBAC.')
param deployElasticSan bool = false

@description('ESAN base capacity in TiB (only used when deployElasticSan = true).')
param esanBaseSizeTiB int = 1

var nameBase = '${prefix}-${suffix}'

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    nameBase: nameBase
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    nameBase: nameBase
  }
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    location: location
    nameBase: nameBase
    kubernetesVersion: kubernetesVersion
    systemVmSize: systemVmSize
    systemNodeCount: systemNodeCount
    storagepoolVmSize: storagepoolVmSize
    storagepoolNodeCount: storagepoolNodeCount
    subnetId: network.outputs.aksSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    adminAadObjectId: adminAadObjectId
    clusterTier: clusterTier
    podCidr: podCidr
    apiServerAuthorizedIPRanges: apiServerAuthorizedIPRanges
  }
}

// Optional Elastic SAN — gated by deployElasticSan param.
// The module scope is set to subscription for the ACS Operator role assignment.
module elasticsan 'modules/elasticsan.bicep' = if (deployElasticSan) {
  name: 'elasticsan'
  params: {
    location: location
    nameBase: nameBase
    kubeletIdentityObjectId: aks.outputs.kubeletIdentityObjectId
    baseSizeTiB: esanBaseSizeTiB
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
output clusterName string = aks.outputs.clusterName
output resourceGroupName string = resourceGroup().name
output kubeletIdentityObjectId string = aks.outputs.kubeletIdentityObjectId
output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output nodeResourceGroup string = aks.outputs.nodeResourceGroup
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output getCredentialsCommand string = 'az aks get-credentials -g ${resourceGroup().name} -n ${aks.outputs.clusterName} --overwrite-existing'
#disable-next-line BCP318
output esanId string = deployElasticSan ? elasticsan.outputs.esanId : ''
#disable-next-line BCP318
output esanVolumeGroupName string = deployElasticSan ? elasticsan.outputs.volumeGroupName : ''
