#!/usr/bin/env bash
# Step 3: configure OpenShift.
#
#   1. Install OpenShift Virtualization.
#   2. Turn on FRR and route advertisements in the cluster network operator.
#   3. Peer the workers with Route Server (cluster/frr-configuration.yaml).
#   4. Create the guest network and two Fedora guests.
#   5. Once the guests have finished cloud-init, advertise the guest network.
#
# Idempotent: safe to rerun.
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az oc jq

CLUSTER="$(output clusterName)"
ROUTE_SERVER="$(output routeServerName)"
CLUSTER_DIR="$REPO_ROOT/cluster"

log "Getting the admin kubeconfig for $CLUSTER"
rm -f "$KUBECONFIG"
az aro get-admin-kubeconfig -g "$RESOURCE_GROUP" -n "$CLUSTER" -f "$KUBECONFIG" -o none
chmod 600 "$KUBECONFIG"
oc whoami --show-server

log "Installing OpenShift Virtualization"
# The pull secret gives access to the redhat-operators catalog. Enable it if needed,
# keeping any other catalog settings.
if ! oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
  sources="$(oc get operatorhub cluster -o json | jq -c '
    [ (.spec.sources // [])[] | select(.name != "redhat-operators") ] + [{name: "redhat-operators", disabled: false}]')"
  oc patch operatorhub cluster --type merge -p "{\"spec\":{\"sources\":$sources}}"
fi
oc apply -f "$CLUSTER_DIR/virtualization-operator.yaml"
csv_ready() {
  oc get csv -n openshift-cnv -o json \
    | jq -e '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged-operator")) | select(.status.phase == "Succeeded")'
}
retry 1800 "the OpenShift Virtualization operator" csv_ready
# The operator's webhook can lag behind the CSV phase.
retry 600 "the HyperConverged webhook to accept the instance" oc apply -f "$CLUSTER_DIR/hyperconverged.yaml"
oc wait hyperconverged/kubevirt-hyperconverged -n openshift-cnv --for=condition=Available --timeout=30m

log "Enabling FRR and route advertisements"
oc patch network.operator cluster --type merge -p '{
  "spec": {
    "additionalRoutingCapabilities": {"providers": ["FRR"]},
    "defaultNetwork": {"ovnKubernetesConfig": {"routeAdvertisements": "Enabled"}}
  }}'
retry 1200 "the frr-k8s DaemonSet" oc get daemonset/frr-k8s -n openshift-frr-k8s
oc rollout status daemonset/frr-k8s -n openshift-frr-k8s --timeout=20m
oc wait crd/frrconfigurations.frrk8s.metallb.io crd/routeadvertisements.k8s.ovn.org \
  --for=condition=Established --timeout=10m

log "Peering the workers with Route Server"
expected="10.0.4.4,10.0.4.5"
actual="$(az network routeserver show -g "$RESOURCE_GROUP" -n "$ROUTE_SERVER" --query 'virtualRouterIps' -o json | jq -r 'sort | join(",")')"
[[ "$actual" == "$expected" ]] \
  || die "Route Server IPs are $actual, but cluster/frr-configuration.yaml uses $expected"
oc label nodes -l node-role.kubernetes.io/worker arovirt.io/bgp-speaker=true --overwrite
# The FRR validating webhook can take a minute to start answering after the rollout.
retry 600 "the FRR webhook to accept the configuration" oc apply -f "$CLUSTER_DIR/frr-configuration.yaml"

bgp_established() { # every worker's FRR (at least 3) has 2 established Route Server sessions
  local pods pod count
  pods="$(worker_frr_pods)"
  (($(wc -w <<<"$pods") >= 3)) || return 1
  for pod in $pods; do
    count="$(frr_bgp_summary "$pod" \
      | jq '[.ipv4Unicast.peers // {} | .[] | select(.state == "Established")] | length')"
    [[ "$count" == 2 ]] || return 1
  done
}
retry 600 "BGP sessions to Route Server" bgp_established
echo "All workers have 2 established BGP sessions"

log "Creating the guest network and guests"
oc apply -f "$CLUSTER_DIR/guest-network.yaml"
oc wait clusteruserdefinednetwork/arovirt-guests --for=condition=NetworkCreated --timeout=5m
oc create secret generic guest-ssh-key -n arovirt-guests \
  --from-file=key="$SSH_PUBLIC_KEY_FILE" --dry-run=client -o yaml | oc apply -f -
oc apply -f "$CLUSTER_DIR/guests.yaml"
oc wait vm --all -n arovirt-guests --for=condition=Ready --timeout=30m

# Advertising the network removes its egress SNAT, which cuts the guests off from
# the internet, so first make sure cloud-init has finished and installed the
# packages. The check runs inside each guest through the guest agent, with the same
# virt-probe helper KubeVirt uses for exec probes.
in_guest() { # in_guest <vm> <executable> [args...]; succeeds if the command exits 0
  local vm="$1" exe="$2" pod
  shift 2
  pod="$(oc get pods -n arovirt-guests -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$vm" \
    --field-selector=status.phase=Running -o name)"
  [[ -n "$pod" ]] || return 1
  oc exec -n arovirt-guests "$pod" -c compute -- /usr/bin/virt-probe \
    --domainName "arovirt-guests_$vm" --timeoutSeconds 10 --command "$exe" -- "$@"
}
guest_ready() {
  in_guest "$1" /usr/bin/test -f /var/lib/cloud/instance/boot-finished \
    && in_guest "$1" /usr/bin/rpm -q tcpdump iperf3 nmap-ncat
}
log "Waiting for the guests to finish cloud-init"
oc wait vmi --all -n arovirt-guests --for=condition=AgentConnected --timeout=20m
for vm in fedora-a fedora-b; do
  retry 1200 "cloud-init to finish in $vm" guest_ready "$vm"
  echo "$vm is ready"
done

log "Advertising the guest network"
oc apply -f "$CLUSTER_DIR/route-advertisements.yaml"
oc wait routeadvertisements/arovirt-guests --for=condition=Accepted --timeout=5m

oc get vmi -n arovirt-guests -o wide
echo
echo "Next: scripts/verify.sh"
