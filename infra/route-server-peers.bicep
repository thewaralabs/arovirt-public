// Adds one Route Server BGP peer per ARO worker (ASN 65001). Each peer gives two
// eBGP sessions, one to each Route Server instance.
//
// Run after the worker NICs have IP forwarding enabled (scripts/02-configure-routing.sh).
// Peers are created one at a time: parallel creates fail with ConflictError.
targetScope = 'resourceGroup'

param routeServerName string

@description('Worker peers: [{ name: <worker VM name>, ip: <worker NIC IP> }].')
@minLength(1)
param peers array

@description('Must match the asn in cluster/frr-configuration.yaml.')
param workerAsn int = 65001

resource routeServer 'Microsoft.Network/virtualHubs@2024-05-01' existing = {
  name: routeServerName
}

@batchSize(1)
resource bgpConnections 'Microsoft.Network/virtualHubs/bgpConnections@2024-05-01' = [
  for peer in peers: {
    parent: routeServer
    name: peer.name
    properties: {
      peerAsn: workerAsn
      peerIp: peer.ip
    }
  }
]
