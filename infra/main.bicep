// ARO x86 virtualization lab: everything on the Azure side, in one resource group.
//
//   ARO VNet (control-plane, workers, RouteServerSubnet)
//   ARO cluster (x86 workers that support nested virtualization)
//   Azure Route Server (BGP control plane for the guest network)
//   Client VNet + Ubuntu test VM, peered to the ARO VNet with gateway transit
//
// Deploy this template once. ARO attaches its own NSGs to the cluster subnets
// after creation, and redeploying the VNet with inline subnets would detach them.
// Route Server BGP peers are added later by route-server-peers.bicep, when the
// worker IPs are known.
targetScope = 'resourceGroup'

@description('Resource name prefix (2-10 lowercase letters or digits, starting with a letter).')
@minLength(2)
@maxLength(10)
param prefix string = 'arovirt'

param location string = resourceGroup().location

@description('Exact ARO OpenShift version, from `az aro get-versions -l <location>`. 4.21 or later is needed for route advertisements.')
param openshiftVersion string

@description('ARO-managed resource group name. ARO creates it; it must not exist yet.')
param managedResourceGroupName string = '${resourceGroup().name}-managed'

@description('Red Hat pull secret JSON from console.redhat.com. Needed to install OpenShift Virtualization from redhat-operators.')
@secure()
param pullSecret string

@description('Application (client) ID of the cluster service principal.')
param clusterSpClientId string

@description('Object ID of the cluster service principal (not the app registration).')
param clusterSpObjectId string

@description('Client secret of the cluster service principal.')
@secure()
param clusterSpClientSecret string

@description('Tenant-specific object ID of the Azure Red Hat OpenShift RP service principal (appId f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875).')
param aroRpObjectId string

@description('Worker VM size. Must support nested virtualization. Easv5 avoided a zone-placement failure seen with Dsv5 workers in Australia East.')
param workerVmSize string = 'Standard_E8as_v5'

@minValue(3)
param workerCount int = 3

param masterVmSize string = 'Standard_D8s_v5'

param aroVnetCidr string = '10.0.0.0/20'
param masterSubnetCidr string = '10.0.0.0/23'
param workerSubnetCidr string = '10.0.2.0/23'

@description('At least /26. Route Server takes the first two usable addresses (.4 and .5) as its BGP endpoints.')
param routeServerSubnetCidr string = '10.0.4.0/26'

param podCidr string = '10.128.0.0/14'
param serviceCidr string = '172.30.0.0/16'

param clientVnetCidr string = '10.50.0.0/16'
param clientSubnetCidr string = '10.50.1.0/24'
param clientVmPrivateIp string = '10.50.1.4'
param clientVmSize string = 'Standard_D2s_v5'
param adminUsername string = 'azureuser'

@description('SSH public key for the client VM.')
param sshPublicKey string

@description('Source IPv4 CIDR allowed to SSH to the client VM, for example 203.0.113.10/32.')
param myIp string

@description('Guest network advertised by the cluster over BGP. Must match cluster/guest-network.yaml.')
param guestCidr string = '10.101.0.0/24'

var suffix = take(uniqueString(resourceGroup().id, prefix), 4)
var clusterName = '${prefix}-aro-${suffix}'

var tags = {
  Environment: 'lab'
  Project: 'arovirt'
  ManagedBy: 'Bicep'
  Owner: 'Nirmal'
  SecurityControl: 'Ignore'
}

var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
var aroNetworkRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '42f3c60f-e7b1-46d7-ba56-6de681664342')

var clientCloudInit = '''
#cloud-config
package_update: true
packages:
  - tcpdump
  - iperf3
  - netcat-openbsd
'''

// ---------------------------------------------------------------- ARO network

resource aroVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-aro-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [aroVnetCidr]
    }
    subnets: [
      {
        name: 'control-plane'
        properties: {
          addressPrefix: masterSubnetCidr
          privateLinkServiceNetworkPolicies: 'Disabled'
          serviceEndpoints: [{ service: 'Microsoft.Storage' }]
        }
      }
      {
        name: 'workers'
        properties: {
          addressPrefix: workerSubnetCidr
          serviceEndpoints: [{ service: 'Microsoft.Storage' }]
        }
      }
      {
        name: 'RouteServerSubnet'
        properties: {
          addressPrefix: routeServerSubnetCidr
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource clusterSpVnetContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aroVnet.id, clusterSpObjectId, contributorRoleId)
  scope: aroVnet
  properties: {
    roleDefinitionId: contributorRoleId
    principalId: clusterSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource aroRpVnetNetwork 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aroVnet.id, aroRpObjectId, aroNetworkRoleId)
  scope: aroVnet
  properties: {
    roleDefinitionId: aroNetworkRoleId
    principalId: aroRpObjectId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- ARO cluster

resource cluster 'Microsoft.RedHatOpenShift/openShiftClusters@2025-07-25' = {
  name: clusterName
  location: location
  tags: tags
  properties: {
    clusterProfile: {
      domain: '${prefix}-${suffix}'
      version: openshiftVersion
      pullSecret: pullSecret
      fipsValidatedModules: 'Disabled'
      resourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)
    }
    servicePrincipalProfile: {
      clientId: clusterSpClientId
      clientSecret: clusterSpClientSecret
    }
    networkProfile: {
      podCidr: podCidr
      serviceCidr: serviceCidr
      outboundType: 'Loadbalancer'
      preconfiguredNSG: 'Disabled'
    }
    masterProfile: {
      vmSize: masterVmSize
      encryptionAtHost: 'Disabled'
      subnetId: '${aroVnet.id}/subnets/control-plane'
    }
    workerProfiles: [
      {
        name: 'worker'
        vmSize: workerVmSize
        count: workerCount
        diskSizeGB: 128
        encryptionAtHost: 'Disabled'
        subnetId: '${aroVnet.id}/subnets/workers'
      }
    ]
    apiserverProfile: {
      visibility: 'Public'
    }
    ingressProfiles: [
      {
        name: 'default'
        visibility: 'Public'
      }
    ]
  }
  // Build the cluster after Route Server and the peerings, so nothing else writes to
  // the VNet while ARO installs and attaches its NSGs.
  dependsOn: [
    clusterSpVnetContributor
    aroRpVnetNetwork
    clientToAro
  ]
}

// ---------------------------------------------------------------- Route Server

resource routeServerPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-rs-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource routeServer 'Microsoft.Network/virtualHubs@2024-05-01' = {
  name: '${prefix}-rs'
  location: location
  tags: tags
  properties: {
    sku: 'Standard'
    allowBranchToBranchTraffic: false
    hubRoutingPreference: 'ASPath'
  }
}

// The IP configuration must be a separate child resource; inline it fails with InvalidJson.
resource routeServerIpConfig 'Microsoft.Network/virtualHubs/ipConfigurations@2024-05-01' = {
  parent: routeServer
  name: 'ipconfig1'
  properties: {
    subnet: {
      id: '${aroVnet.id}/subnets/RouteServerSubnet'
    }
    publicIPAddress: {
      id: routeServerPip.id
    }
  }
}

// ---------------------------------------------------------------- client network and VM

resource clientNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-client-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-MyIp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: myIp
          sourcePortRange: '*'
          destinationAddressPrefix: clientVmPrivateIp
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-Guests-Tcp5201'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: guestCidr
          sourcePortRange: '*'
          destinationAddressPrefix: clientVmPrivateIp
          destinationPortRange: '5201'
        }
      }
      {
        name: 'Allow-Guests-Udp5201'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: guestCidr
          sourcePortRange: '*'
          destinationAddressPrefix: clientVmPrivateIp
          destinationPortRange: '5201'
        }
      }
      {
        name: 'Allow-Guests-Icmp'
        properties: {
          priority: 220
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourceAddressPrefix: guestCidr
          sourcePortRange: '*'
          destinationAddressPrefix: clientVmPrivateIp
          destinationPortRange: '*'
        }
      }
      {
        // Overrides the default AllowVNetInBound, which would allow everything over the peering.
        name: 'Deny-Other-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource clientVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-client-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [clientVnetCidr]
    }
    subnets: [
      {
        name: 'client'
        properties: {
          addressPrefix: clientSubnetCidr
          networkSecurityGroup: {
            id: clientNsg.id
          }
        }
      }
    ]
  }
}

resource clientPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-client-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-client-nic'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: clientVmPrivateIp
          subnet: {
            id: clientVnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: clientPip.id
          }
        }
      }
    ]
  }
}

resource clientVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${prefix}-client'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: clientVmSize
    }
    osProfile: {
      computerName: '${prefix}-client'
      adminUsername: adminUsername
      customData: base64(clientCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clientNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------- peering

// Gateway transit on the ARO side plus use-remote-gateways on the client side is what
// lets Route Server program the BGP-learned guest route into the client VNet. Both
// flags require Route Server to exist first, hence the dependency on its IP config.
resource aroToClient 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: aroVnet
  name: 'aro-to-client'
  properties: {
    remoteVirtualNetwork: {
      id: clientVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
  dependsOn: [
    routeServerIpConfig
  ]
}

resource clientToAro 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: clientVnet
  name: 'client-to-aro'
  properties: {
    remoteVirtualNetwork: {
      id: aroVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
  dependsOn: [
    aroToClient
  ]
}

output clusterName string = cluster.name
output managedResourceGroupName string = managedResourceGroupName
output routeServerName string = routeServer.name
output clientVmName string = clientVm.name
output clientVmPublicIp string = clientPip.properties.ipAddress
output clientVmPrivateIp string = clientVmPrivateIp
output consoleUrl string = cluster.properties.consoleProfile.url
output apiServerUrl string = cluster.properties.apiserverProfile.url
