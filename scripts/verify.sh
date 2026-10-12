#!/usr/bin/env bash
# Read-only check that the guest network is routed natively, end to end:
# BGP sessions, Route Server learned routes, the client VM's effective routes,
# and ping from the client VM to each guest at its own IP.
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az oc jq ssh

ROUTE_SERVER="$(output routeServerName)"
CLIENT_IP="$(output clientVmPublicIp)"
CLIENT_NIC="$(output clientVmName)-nic"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig at $KUBECONFIG; run scripts/03-configure-cluster.sh first"
failures=0
check() { if "$@" >/dev/null 2>&1; then echo "PASS"; else echo "FAIL"; failures=$((failures + 1)); fi; }

log "BGP sessions on each worker"
pods="$(worker_frr_pods)"
printf '  FRR running on at least 3 workers: '
check test "$(wc -w <<<"$pods")" -ge 3
for pod in $pods; do
  node="$(oc get pod -n openshift-frr-k8s "$pod" -o jsonpath='{.spec.nodeName}')"
  summary="$(frr_bgp_summary "$pod")"
  jq -r --arg n "$node" '.ipv4Unicast.peers // {} | to_entries[]
    | "  \($n)  \(.key)  \(.value.state)  received \(.value.pfxRcd // 0)  sent \(.value.pfxSnt // 0)"' <<<"$summary"
  printf '  2 established sessions: '
  check jq -e '[.ipv4Unicast.peers // {} | .[] | select(.state == "Established")] | length == 2' <<<"$summary"
done

log "Routes Route Server learned for $GUEST_CIDR"
for peer in $(az network routeserver peering list -g "$RESOURCE_GROUP" --routeserver "$ROUTE_SERVER" --query '[].name' -o tsv); do
  routes="$(az network routeserver peering list-learned-routes -g "$RESOURCE_GROUP" --routeserver "$ROUTE_SERVER" -n "$peer" -o json)"
  jq -r --arg p "$GUEST_CIDR" '.[][] | select(.network == $p) | "  \(.localAddress)  \(.network)  via \(.nextHop)  AS \(.asPath)"' <<<"$routes"
  printf '  %s learned by both instances: ' "$peer"
  check jq -e --arg p "$GUEST_CIDR" '[.[][] | select(.network == $p)] | length == 2' <<<"$routes"
done

log "Effective routes for $GUEST_CIDR on the client VM NIC"
routes="$(az network nic show-effective-route-table -g "$RESOURCE_GROUP" -n "$CLIENT_NIC" -o json)"
jq -r --arg p "$GUEST_CIDR" '.value[] | select(.addressPrefix | index($p))
  | "  \(.source)  \(.state)  \(.nextHopType)  \(.nextHopIpAddress | join(","))"' <<<"$routes"
printf '  active BGP route present: '
check jq -e --arg p "$GUEST_CIDR" 'any(.value[]; (.addressPrefix | index($p)) and .state == "Active" and .nextHopType == "VirtualNetworkGateway")' <<<"$routes"

log "Guests"
oc get vmi -n arovirt-guests -o wide
for ip in $(oc get vmi -n arovirt-guests -o json | jq -r '.items[].status.interfaces[0].ipAddress'); do
  printf '  ping %s from the client VM: ' "$ip"
  check client_ssh "ping -c 3 -W 2 $ip"
done

echo
if ((failures)); then die "$failures check(s) failed"; fi
echo "All checks passed. SSH to a guest: ssh -J azureuser@$CLIENT_IP fedora@<guest IP>"
