#!/usr/bin/env bash
# Step 2: let the ARO workers route the guest network.
#
#   1. Enable IP forwarding on each worker NIC, so Azure delivers packets addressed
#      to guest IPs to the worker (and accepts replies sourced from them).
#   2. Add each worker as a Route Server BGP peer (infra/route-server-peers.bicep).
#
# The worker NICs live in the ARO-managed resource group, behind a deny assignment.
# A user, even an Owner, gets LinkedAuthorizationFailed (the NIC is joined to the
# ARO load balancer). The cluster service principal is exempt from the deny
# assignment, so this script makes the NIC change as that principal, through the
# ARM REST API. Changing managed resources is outside normal ARO support.
#
# Forwarding does not carry over to new workers (scale-out, repair, upgrade). Rerun
# this script, and then step 3, after any worker change. It is idempotent.
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az jq curl

: "${ARO_CLIENT_ID:?export ARO_CLIENT_ID (cluster service principal app ID)}"
: "${ARO_CLIENT_SECRET:?export ARO_CLIENT_SECRET (cluster service principal secret)}"
export ARO_CLIENT_ID ARO_CLIENT_SECRET

ARM="https://management.azure.com"
NIC_API="api-version=2024-05-01"
ROUTE_SERVER="$(output routeServerName)"

log "Signing in as the cluster service principal"
# The secret goes to curl on stdin and the token in a header file descriptor, so
# neither appears in the process list.
TOKEN="$(printf '%s' "$ARO_CLIENT_SECRET" | curl -fsS \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$ARO_CLIENT_ID" \
  --data-urlencode "client_secret@-" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=$ARM/.default" | jq -r .access_token)" \
  || die "token request for the cluster service principal failed; check ARO_CLIENT_ID, ARO_CLIENT_SECRET and the tenant"
[[ -n "$TOKEN" && "$TOKEN" != null ]] || die "could not get a token for the cluster service principal"

arm() { # arm <method> <resource id> [curl args...]; prints Azure's error body on failure
  local method="$1" id="$2" out
  shift 2
  if ! out="$(curl -sS --fail-with-body -X "$method" "$ARM$id?$NIC_API" \
      -H @<(printf 'Authorization: Bearer %s\n' "$TOKEN") "$@")"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

log "Finding worker NICs in $MANAGED_RESOURCE_GROUP"
WORKERS="$(az network nic list -g "$MANAGED_RESOURCE_GROUP" -o json | jq -c '
  [ .[] | select(.virtualMachine.id != null and (.virtualMachine.id | test("-worker-")))
    | { id, name: (.virtualMachine.id | split("/") | last), ip: .ipConfigurations[0].privateIPAddress } ]')"
[[ "$(jq length <<<"$WORKERS")" -ge 3 ]] || die "expected at least 3 worker NICs, found: $WORKERS"
jq -r '.[] | "  \(.name)  \(.ip)"' <<<"$WORKERS"

log "Enabling IP forwarding on the worker NICs"
for id in $(jq -r '.[].id' <<<"$WORKERS"); do
  nic="$(arm GET "$id")"
  if [[ "$(jq -r .properties.enableIPForwarding <<<"$nic")" == true ]]; then
    echo "  ${id##*/}: already enabled"
    continue
  fi
  # PUT the full NIC body back with one change. If-Match guards against concurrent edits.
  jq '.properties.enableIPForwarding = true' <<<"$nic" \
    | arm PUT "$id" -H 'Content-Type: application/json' -H "If-Match: $(jq -r .etag <<<"$nic")" -d @- >/dev/null
  # The PUT can return 200 while still Updating; poll the NIC itself.
  nic_done() { arm GET "$id" | jq -e '.properties.provisioningState == "Succeeded" and .properties.enableIPForwarding == true'; }
  retry 600 "IP forwarding on ${id##*/}" nic_done
  echo "  ${id##*/}: enabled"
done

log "Adding the workers as Route Server BGP peers"
PARAMS="$STATE_DIR/route-server-peers.parameters.json"
jq -n --arg rs "$ROUTE_SERVER" --argjson workers "$WORKERS" '{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  contentVersion: "1.0.0.0",
  parameters: { routeServerName: { value: $rs }, peers: { value: [ $workers[] | { name, ip } ] } }
}' >"$PARAMS"
az deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME-peers" \
  -f "$REPO_ROOT/infra/route-server-peers.bicep" -p @"$PARAMS" -o none

az network routeserver peering list -g "$RESOURCE_GROUP" --routeserver "$ROUTE_SERVER" \
  --query '[].{name:name, peerIp:peerIp, peerAsn:peerAsn, state:provisioningState}' -o table
echo
echo "Route Server BGP IPs: $(az network routeserver show -g "$RESOURCE_GROUP" -n "$ROUTE_SERVER" --query "join(', ', virtualRouterIps)" -o tsv)"
echo "Next: scripts/03-configure-cluster.sh"
