param location string
param nameBase string
param kubernetesVersion string
param systemVmSize string
param systemNodeCount int
param subnetId string
param logAnalyticsWorkspaceId string
param adminAadObjectId string

// ── Best practice: Standard tier (SLA-backed control plane). Issue #26.
@description('AKS cluster tier. Standard gives 99.9% API server SLA + autoscaler support.')
param clusterTier string = 'Standard'

// ── v2.1: storagepool node pool params ───────────────────────────────────────
@description('VM size for the dedicated storage node pool (must support local NVMe).')
param storagepoolVmSize string = 'Standard_L8s_v3'

@description('Number of nodes in the storage node pool. 3 = one per zone (minimum for AZ spread).')
param storagepoolNodeCount int = 3

// ── Best practice: CNI Overlay pod CIDR. Issue #24.
@description('Pod CIDR for Azure CNI Overlay. Not routed in the VNet. 100.64.0.0/10 gives ~4M pod IPs.')
param podCidr string = '100.64.0.0/10'

// ── Best practice: API server authorised IP ranges. Issue #31.
@description('Restrict kubectl/API server access to these CIDRs. Empty = unrestricted (dev convenience).')
param apiServerAuthorizedIPRanges array = []

var clusterName = 'aks-${nameBase}'
var uaiName = 'id-aks-${nameBase}'

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  name: uaiName
  location: location
}

// Bump API version to 2025-01-01 — supports nodeRestriction, imageCleaner,
// autoUpgradeProfile.nodeOSUpgradeChannel, and networkPluginMode=overlay.
resource aks 'Microsoft.ContainerService/managedClusters@2025-01-01' = {
  name: clusterName
  location: location

  // ── Best practice: Standard tier SLA. Issue #26.
  sku: {
    name: 'Base'
    tier: clusterTier
  }

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

    // ── Best practice: patch auto-upgrade + NodeImage OS upgrade. Issue #25.
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }

    oidcIssuerProfile: {
      enabled: true
    }

    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      // ── Best practice: Node Restriction prevents nodes from labelling
      //    themselves or reading other nodes' secrets. Issue #29.
      //    Bicep type defs lag the API for this property — suppress the warning.
      #disable-next-line BCP037
      nodeRestriction: {
        enabled: true
      }
      // ── Best practice: Image Cleaner removes stale/unused images from nodes
      //    every 48 h, reducing CVE surface. Issue #29.
      imageCleaner: {
        enabled: true
        intervalHours: 48
      }
    }

    aadProfile: empty(adminAadObjectId) ? null : {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: [
        adminAadObjectId
      ]
    }

    // ── Best practice: authorised IP ranges on the API server. Issue #31.
    apiServerAccessProfile: {
      authorizedIPRanges: apiServerAuthorizedIPRanges
    }

    agentPoolProfiles: [
      {
        // System pool: lightweight, no storage role.
        // Ephemeral OS disk — no extra managed disk cost, faster boot. Issue #28.
        name: 'syspool'
        mode: 'System'
        count: systemNodeCount
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskSizeGB: 128
        osDiskType: 'Ephemeral'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: subnetId
        // Overlay: pod IPs come from podCidr, not the subnet — raise maxPods from 30→110. Issue #27.
        maxPods: 110
        // ── Best practice: autoscaler on syspool. Issue #27.
        enableAutoScaling: true
        minCount: 2
        maxCount: 4
        nodeLabels: {}
        upgradeSettings: {
          // Surge to keep one extra node available during upgrades.
          maxSurge: '1'
        }
      }
      {
        // Storage pool: Lsv3 NVMe nodes, spread across zones 1/2/3.
        // ACStor components are targeted here via the local-nvme StorageClass
        // annotation: storageoperator.acstor.io/nodeAffinity (agentpool=storagepool).
        // OS disk stays Managed (Ephemeral would conflict with ACS NVMe pool setup). Issue #28.
        name: 'storagepool'
        mode: 'User'
        count: storagepoolNodeCount
        vmSize: storagepoolVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: subnetId
        availabilityZones: ['1', '2', '3']
        // Overlay: raise from 30 → 110. Issue #27.
        maxPods: 110
        // ── Best practice: autoscaler, never below 3 (zone spread). Issue #27.
        enableAutoScaling: true
        minCount: 3
        maxCount: 6
        nodeLabels: {
          'acstor.azure.com/io-engine': 'acstor'
        }
        // Optional taint to keep non-storage workloads off Lsv3 nodes.
        // Remove if you want general workloads to run here too.
        nodeTaints: [
          'storage=nvme:NoSchedule'
        ]
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      // ── Best practice: Overlay mode. Pods get IPs from podCidr, not the
      //    node subnet. AKS Automatic default. Issue #24.
      networkPluginMode: 'overlay'
      podCidr: podCidr
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
