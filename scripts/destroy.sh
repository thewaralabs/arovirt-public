#!/usr/bin/env bash
# Deletes the lab: the ARO cluster (which removes its managed resource group), the
# resource group and the managed resource group tagging policy. The cluster service
# principal is left alone; delete it yourself if you no longer need it.
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az

read -r -p "Type the resource group name ($RESOURCE_GROUP) to delete the lab: " answer
[[ "$answer" == "$RESOURCE_GROUP" ]] || die "confirmation did not match; nothing deleted"

if az group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
  for cluster in $(az aro list -g "$RESOURCE_GROUP" --query '[].name' -o tsv); do
    log "Deleting ARO cluster $cluster (about 20 minutes)"
    az aro delete -g "$RESOURCE_GROUP" -n "$cluster" --yes
  done
  log "Deleting resource group $RESOURCE_GROUP"
  az group delete -n "$RESOURCE_GROUP" --yes
fi

policy="$(az deployment sub show -n "$DEPLOYMENT_NAME-mrg-tag-policy" --query properties.outputs.policyName.value -o tsv 2>/dev/null || true)"
if [[ -n "$policy" ]]; then
  log "Deleting tagging policy $policy"
  az policy assignment delete -n "$policy"
  az policy definition delete -n "$policy"
  az deployment sub delete -n "$DEPLOYMENT_NAME-mrg-tag-policy"
fi

rm -rf "$STATE_DIR"
log "Lab deleted"
