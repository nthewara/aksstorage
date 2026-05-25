@description('Location for all resources.')
param location string = 'australiaeast'

@description('Short prefix for resource names. Lowercase, 3-8 chars.')
@minLength(3)
@maxLength(8)
param prefix string = 'acsl'

@description('Suffix appended to resource names (kept short for uniqueness).')
param suffix string = uniqueString(resourceGroup().id)

@description('Kubernetes version. Leave blank to use AKS default.')
param kubernetesVersion string = '1.30'

@description('System node pool VM size.')
param systemVmSize string = 'Standard_D4s_v5'

@description('System node count.')
param systemNodeCount int = 3

@description('Object ID of the principal (user / SP) that will get cluster-admin via AAD. Optional.')
param adminAadObjectId string = ''

@description('Enable Azure Container Storage extension via storageProfile (preview surface; safe to keep false and install via CLI post-deploy).')
param enableAcstorViaStorageProfile bool = false

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
    subnetId: network.outputs.aksSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    adminAadObjectId: adminAadObjectId
    enableAcstorViaStorageProfile: enableAcstorViaStorageProfile
  }
}

// Contributor on the node resource group for the kubelet identity (needed for ACStor
// to attach managed disks). Scoping at RG level is the minimum the kubelet needs.
// Contributor assignment for kubelet identity is created in modules/aks.bicep where the
// identity objectId is available as a known property. Keeping it here would require a
// runtime value in the role assignment name (BCP120).

output clusterName string = aks.outputs.clusterName
output resourceGroupName string = resourceGroup().name
output kubeletIdentityObjectId string = aks.outputs.kubeletIdentityObjectId
output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output nodeResourceGroup string = aks.outputs.nodeResourceGroup
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output getCredentialsCommand string = 'az aks get-credentials -g ${resourceGroup().name} -n ${aks.outputs.clusterName} --overwrite-existing'
