#!/usr/bin/env bash
# Live proofs for the customer demo, so the presenter does not type long commands.
# See docs/run-and-demo.md for the run sheet.
#
# It changes nothing in Azure or the cluster. The traffic proofs start short-lived
# listeners on the client VM or a guest. Each serves one request or a fixed number
# of packets and is bounded by `timeout`, so nothing is left running.

usage() {
  cat <<'EOF'
Usage: scripts/demo.sh <command> [a|b]

  env            print export lines for the demo shell: eval "$(scripts/demo.sh env)"
  status         nodes, guests with their IPs and nodes, route advertisements, FRR pods
  bgp            BGP sessions on each worker, and the routes Route Server learned and advertises
  routes         the client VM NIC's effective routes for the guest network
  inbound [a|b]  client VM -> guest over HTTP; the guest logs the client's real IP
  outbound [a|b] guest -> client VM over HTTP; the client logs the guest's real IP
  capture [a|b]  tcpdump on the guest while the client VM pings it
  udp [a|b]      iperf3 UDP from the client VM to the guest for 5 seconds

a and b are the guests fedora-a and fedora-b (default a).
EOF
}

case "${1:-}" in
  env | status | bgp | routes | inbound | outbound | capture | udp) ;;
  "" | -h | --help | help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
COMMAND="$1"
shift

# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az oc jq ssh

PORT=5201                # allowed from the guests by the client VM's NSG
LISTEN_SECONDS=30        # upper bound for every listener this script starts
# Python's http.server, serving exactly one request (Fedora and Ubuntu both have python3).
# It prints "listening on" once bound, so the caller knows when to send the request.
SERVE_ONCE='import http.server, sys; s = http.server.HTTPServer((sys.argv[1], int(sys.argv[2])), http.server.SimpleHTTPRequestHandler); print("listening on", sys.argv[1], sys.argv[2], file=sys.stderr, flush=True); s.handle_request()'
CURL_FORMAT='HTTP %{http_code} from %{remote_ip}:%{remote_port}, local %{local_ip}\n'

WORK="$(mktemp -d)"
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ lookups

# Reads all outputs of the main deployment in one call.
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUTPUTS"; }
load_outputs() {
  OUTPUTS="$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.outputs -o json)" \
    || die "no deployment $DEPLOYMENT_NAME in $RESOURCE_GROUP; run scripts/01-deploy-azure.sh first"
  CLUSTER="$(out clusterName)"
  MRG="$(out managedResourceGroupName)"
  RS="$(out routeServerName)"
  CLIENT_IP="$(out clientVmPublicIp)"
  CLIENT_PRIVATE_IP="$(out clientVmPrivateIp)"
  CLIENT_NIC="$(out clientVmName)-nic"
}

need_kubeconfig() {
  [[ -f "$KUBECONFIG" ]] || die "no kubeconfig at $KUBECONFIG; run scripts/03-configure-cluster.sh first"
}

pick_guest() { # pick_guest [a|b]; prints the VM name
  case "${1:-a}" in
    a | b) echo "fedora-${1:-a}" ;;
    *) die "guest must be a or b, not '$1'" ;;
  esac
}

vmi_ip() { # vmi_ip <vm>; empty if the guest has no IP yet
  oc get vmi "$1" -n arovirt-guests -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true
}

guest_ip() { # guest_ip <vm>
  local ip
  ip="$(vmi_ip "$1")"
  [[ -n "$ip" ]] || die "$1 has no IP; check: oc get vmi -n arovirt-guests"
  echo "$ip"
}

# ------------------------------------------------------------------ helpers for the traffic proofs

wait_for() { # wait_for <file> <text> <seconds>
  local deadline=$((SECONDS + $3))
  until grep -qF -- "$2" "$1"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

fail_with() { # fail_with <log file> <message>
  echo "Listener output:" >&2
  grep -v '^Warning: Permanently added' "$1" >&2 || true
  die "$2"
}

curl_cmd() { # curl_cmd <url>
  echo "curl -sS -o /dev/null --connect-timeout 5 --max-time 10 -w '$CURL_FORMAT' $1"
}

serve_once_cmd() { # serve_once_cmd <bind IP>
  echo "cd /tmp && timeout $LISTEN_SECONDS python3 -c '$SERVE_ONCE' $1 $PORT"
}

# Shows the access log line and checks which source address the server saw.
show_access() { # show_access <log file> <expected source IP> <server name>
  local line
  line="$(grep -F '"GET / ' "$1")" || fail_with "$1" "$3 logged no request"
  echo "  $line"
  if [[ "${line%% *}" == "$2" ]]; then
    echo "  $3 saw the source address $2: PASS"
  else
    die "$3 saw the source address ${line%% *}, expected $2"
  fi
}

# ------------------------------------------------------------------ commands

cmd_env() {
  load_outputs
  printf 'export %s=%q\n' \
    RG "$RESOURCE_GROUP" CLUSTER "$CLUSTER" MRG "$MRG" RS "$RS" CLIENT_IP "$CLIENT_IP" \
    GA "$(vmi_ip fedora-a)" GB "$(vmi_ip fedora-b)" KUBECONFIG "$KUBECONFIG"
}

cmd_status() {
  need_kubeconfig
  log "Nodes"
  oc get nodes -o wide
  log "Guests (IP and node)"
  oc get vmi -n arovirt-guests -o wide
  log "Route advertisements"
  oc get routeadvertisements
  log "FRR pods"
  oc get pods -n openshift-frr-k8s -l app=frr-k8s -o wide
}

cmd_bgp() {
  local pod node peer first=""
  need_kubeconfig
  load_outputs
  log "BGP sessions on each worker (ASN 65001 to Route Server, ASN 65515)"
  for pod in $(worker_frr_pods); do
    node="$(oc get pod -n openshift-frr-k8s "$pod" -o jsonpath='{.spec.nodeName}')"
    frr_bgp_summary "$pod" | jq -r --arg n "$node" '.ipv4Unicast.peers // {} | to_entries[]
      | "  \($n)  \(.key)  \(.value.state)  up \(.value.peerUptime // "-")  received \(.value.pfxRcd // 0)  sent \(.value.pfxSnt // 0)"'
  done

  log "Routes Route Server learned for $GUEST_CIDR (10-15 seconds per peer)"
  for peer in $(az network routeserver peering list -g "$RESOURCE_GROUP" --routeserver "$RS" --query '[].name' -o tsv); do
    first="${first:-$peer}"
    az network routeserver peering list-learned-routes -g "$RESOURCE_GROUP" --routeserver "$RS" -n "$peer" -o json \
      | jq -r --arg p "$GUEST_CIDR" '.[][] | select(.network == $p) | "  \(.localAddress)  \(.network)  via \(.nextHop)  AS \(.asPath)"'
  done
  [[ -n "$first" ]] || die "Route Server $RS has no BGP peers; run scripts/02-configure-routing.sh"

  log "Routes Route Server advertises to $first (the workers accept only 10.50.0.0/16)"
  az network routeserver peering list-advertised-routes -g "$RESOURCE_GROUP" --routeserver "$RS" -n "$first" -o json \
    | jq -r '.[][] | "  \(.localAddress)  \(.network)  AS \(.asPath)"' \
    || echo "  advertised routes are not available"
}

cmd_routes() {
  load_outputs
  log "Worker NICs (the expected next hops)"
  az network nic list -g "$MRG" \
    --query "[?contains(name, 'worker')].{name:name, ip:ipConfigurations[0].privateIPAddress, ipForwarding:enableIPForwarding}" -o table
  log "Effective routes for $GUEST_CIDR on $CLIENT_NIC (about 20 seconds)"
  az network nic show-effective-route-table -g "$RESOURCE_GROUP" -n "$CLIENT_NIC" -o json \
    | jq -r --arg p "$GUEST_CIDR" '.value[] | select(.addressPrefix | index($p))
      | "  \(.source)  \(.state)  \(.addressPrefix | join(","))  \(.nextHopType)  \(.nextHopIpAddress | join(","))"'
}

cmd_inbound() {
  local vm ip server
  vm="$(pick_guest "${1:-}")"
  need_kubeconfig
  ip="$(guest_ip "$vm")"
  load_outputs
  log "$vm ($ip) serves one HTTP request on port $PORT"
  guest_ssh "$ip" "$(serve_once_cmd "$ip")" >"$WORK/server.log" 2>&1 &
  server=$!
  wait_for "$WORK/server.log" "listening on" 20 || fail_with "$WORK/server.log" "the web server did not start on $vm"
  log "arovirt-client ($CLIENT_PRIVATE_IP) requests http://$ip:$PORT/"
  client_ssh "$(curl_cmd "http://$ip:$PORT/")" || fail_with "$WORK/server.log" "the request from the client VM failed"
  wait "$server" || true
  log "Access log on $vm"
  show_access "$WORK/server.log" "$CLIENT_PRIVATE_IP" "$vm"
}

cmd_outbound() {
  local vm ip node node_ip server
  vm="$(pick_guest "${1:-}")"
  need_kubeconfig
  ip="$(guest_ip "$vm")"
  node="$(oc get vmi "$vm" -n arovirt-guests -o jsonpath='{.status.nodeName}')"
  node_ip="$(oc get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  load_outputs
  echo "$vm runs on worker $node ($node_ip). With SNAT, the client VM would see $node_ip."
  log "arovirt-client ($CLIENT_PRIVATE_IP) serves one HTTP request on port $PORT"
  client_ssh "$(serve_once_cmd "$CLIENT_PRIVATE_IP")" >"$WORK/server.log" 2>&1 &
  server=$!
  wait_for "$WORK/server.log" "listening on" 20 || fail_with "$WORK/server.log" "the web server did not start on arovirt-client"
  log "$vm ($ip) requests http://$CLIENT_PRIVATE_IP:$PORT/"
  guest_ssh "$ip" "$(curl_cmd "http://$CLIENT_PRIVATE_IP:$PORT/")" || fail_with "$WORK/server.log" "the request from $vm failed"
  wait "$server" || true
  log "Access log on arovirt-client"
  show_access "$WORK/server.log" "$ip" "arovirt-client"
}

cmd_capture() {
  local vm ip capture
  vm="$(pick_guest "${1:-}")"
  need_kubeconfig
  ip="$(guest_ip "$vm")"
  load_outputs
  log "tcpdump on $vm ($ip): 6 ICMP packets to or from $CLIENT_PRIVATE_IP"
  guest_ssh "$ip" "sudo timeout $LISTEN_SECONDS tcpdump -lni any -c 6 'icmp and host $CLIENT_PRIVATE_IP'" >"$WORK/capture.log" 2>&1 &
  capture=$!
  wait_for "$WORK/capture.log" "listening on" 20 || fail_with "$WORK/capture.log" "tcpdump did not start on $vm"
  log "arovirt-client pings $ip"
  client_ssh "ping -c 3 -W 2 $ip" || true
  wait "$capture" || true
  log "Capture on $vm"
  grep -v '^Warning: Permanently added' "$WORK/capture.log" | sed 's/^/  /'
  grep -qF "IP $CLIENT_PRIVATE_IP > $ip: ICMP echo request" "$WORK/capture.log" \
    || die "the capture has no echo request from $CLIENT_PRIVATE_IP"
  echo "  $vm received the pings from $CLIENT_PRIVATE_IP itself: PASS"
}

cmd_udp() {
  local vm ip server
  vm="$(pick_guest "${1:-}")"
  need_kubeconfig
  ip="$(guest_ip "$vm")"
  load_outputs
  log "iperf3 server on $vm ($ip), port $PORT, one test"
  guest_ssh "$ip" "timeout $LISTEN_SECONDS iperf3 -s -1 -p $PORT --forceflush" >"$WORK/iperf.log" 2>&1 &
  server=$!
  wait_for "$WORK/iperf.log" "Server listening" 20 || fail_with "$WORK/iperf.log" "iperf3 did not start on $vm"
  log "arovirt-client sends UDP to $ip for 5 seconds at 10 Mbit/s"
  client_ssh "iperf3 -c $ip -p $PORT -u -b 10M -t 5" || fail_with "$WORK/iperf.log" "iperf3 from the client VM failed"
  wait "$server" || true
  log "What the iperf3 server on $vm saw"
  grep -E 'Accepted connection|connected to' "$WORK/iperf.log" | sed 's/^/  /' || true
}

"cmd_$COMMAND" "$@"
