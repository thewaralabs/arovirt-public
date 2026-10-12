# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# Shared setup for the lab scripts. Source it; do not run it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_ROOT/.arovirt"
DEPLOYMENT_NAME="arovirt"
export KUBECONFIG="$STATE_DIR/kubeconfig"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "$cmd is required"
  done
}

[[ -f "$REPO_ROOT/lab.env" ]] || die "copy lab.env.example to lab.env and edit it first"
# shellcheck source=/dev/null
source "$REPO_ROOT/lab.env"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP in lab.env}"
: "${LOCATION:?set LOCATION in lab.env}"
MANAGED_RESOURCE_GROUP="$RESOURCE_GROUP-managed"

GUEST_CIDR="10.101.0.0/24"   # must match cluster/guest-network.yaml

# Read-only callers (00-preflight.sh) set AROVIRT_READ_ONLY=1 before sourcing this
# file, to skip the steps below that change local or Azure CLI state.
if [[ "${AROVIRT_READ_ONLY:-}" != 1 ]]; then
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

  # Note: this changes the Azure CLI default subscription for your other shells too.
  if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$SUBSCRIPTION_ID"
  fi
  TENANT_ID="$(az account show --query tenantId -o tsv)"
fi

# Reads one output of the main deployment.
output() {
  az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --query "properties.outputs.$1.value" -o tsv
}

# Polls a command until it succeeds: retry <timeout seconds> <description> <command...>
# On timeout, prints the command's last output so the real error is visible.
retry() {
  local timeout="$1" what="$2" deadline=$((SECONDS + $1)) out
  shift 2
  until out="$("$@" 2>&1)"; do
    if ((SECONDS >= deadline)); then
      printf '%s\n' "$out" >&2
      die "timed out after ${timeout}s waiting for $what"
    fi
    sleep 15
  done
}

# The FRR pods on the workers (the BGP speakers), one name per line.
worker_frr_pods() {
  oc get pods -n openshift-frr-k8s -l app=frr-k8s -o json \
    | jq -r '.items[] | select(.spec.nodeName | test("-worker-")) | .metadata.name'
}

# One FRR pod's BGP summary, as JSON: frr_bgp_summary <pod>
frr_bgp_summary() {
  oc exec -n openshift-frr-k8s "$1" -c frr -- vtysh -c 'show bgp summary json'
}

# SSH to the client VM, and through it to a guest. The guests are reached only over
# the routed network, with the client VM as a jump host. ProxyCommand, rather than
# -J, applies the same options to the jump hop. Callers set CLIENT_IP.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
client_ssh() { # client_ssh <command>
  # shellcheck disable=SC2029  # the command is meant to expand here and run remotely
  ssh "${SSH_OPTS[@]}" "azureuser@$CLIENT_IP" "$@"
}
guest_ssh() { # guest_ssh <guest IP> <command>
  local ip="$1"
  shift
  ssh "${SSH_OPTS[@]}" -o "ProxyCommand=ssh ${SSH_OPTS[*]} -W %h:%p azureuser@$CLIENT_IP" "fedora@$ip" "$@"
}
