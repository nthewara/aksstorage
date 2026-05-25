param location string
param nameBase string
param kubernetesVersion string
param systemVmSize string
param systemNodeCount int
param subnetId string
param logAnalyticsWorkspaceId string
param adminAadObjectId string

// v2.1: storagepool node pool params
@description('VM size for the dedicated storage node pool (must support local NVMe).')
param storagepoolVmSize string = 'Standard_L8s_v3'

@description('Number of nodes in the storage node pool. 3 = one per zone.')
param storagepoolNodeCount int = 3

var clusterName = 'aks-${nameBase}'
var uaiName = 'id-aks-${nameBase}'

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  name: uaiName
  location: location
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: clusterName
    enableRBAC: true
    disableLocalAccounts: !empty(adminAadObjectId)
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    aadProfile: empty(adminAadObjectId) ? null : {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: [
        adminAadObjectId
      ]
    }
    agentPoolProfiles: [
      {
        // System pool: lightweight, no storage role
        name: 'syspool'
        mode: 'System'
        count: systemNodeCount
        vmSize: systemVmSize
        osType: 'Linux'
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: subnetId
        nodeLabels: {}
      }
      {
        // Storage pool: Lsv3 NVMe nodes, spread across zones 1/2/3
        // ACStor components are targeted here via the local-nvme StorageClass
        // annotation: storageoperator.acstor.io/nodeAffinity (agentpool=storagepool)
        name: 'storagepool'
        mode: 'User'
        count: storagepoolNodeCount
        vmSize: storagepoolVmSize
        osType: 'Linux'
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: subnetId
        availabilityZones: ['1', '2', '3']
        nodeLabels: {
          'acstor.azure.com/io-engine': 'acstor'
        }
        // Optional taint to keep non-storage workloads off Lsv3 nodes.
        // Remove if you want general workloads to run here too.
        nodeTaints: [
          'storage=nvme:NoSchedule'
        ]
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'cilium'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      serviceCidr: '10.50.0.0/16'
      dnsServiceIP: '10.50.0.10'
    }
    storageProfile: {
      diskCSIDriver: { enabled: true }
      fileCSIDriver: { enabled: true }
      snapshotController: { enabled: true }
      // ACStor v2.1: do NOT enable via storageProfile — use CLI post-deploy
      // for full v2.1 modular-install support (Flow A or B). See docs/LAB.md.
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
    }
  }
}

// Diagnostic settings → Log Analytics
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: aks
  name: 'to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'kube-apiserver', enabled: true }
      { category: 'kube-controller-manager', enabled: true }
      { category: 'kube-scheduler', enabled: true }
      { category: 'kube-audit', enabled: true }
      { category: 'cluster-autoscaler', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// Contributor on the current RG for the kubelet identity (lets ACStor attach disks).
resource kubeletRgContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, clusterName, 'kubelet-contributor')
  scope: resourceGroup()
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

output clusterName string = aks.name
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output nodeResourceGroup string = aks.properties.nodeResourceGroup
output userAssignedIdentityId string = uai.id
