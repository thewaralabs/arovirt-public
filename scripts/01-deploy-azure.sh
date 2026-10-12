#!/usr/bin/env bash
# Step 1: deploy the Azure side (ARO, Route Server, client VNet and VM) from
# infra/main.bicep. Takes 60-80 minutes, mostly ARO.
#
# Needs: lab.env, ARO_CLIENT_ID and ARO_CLIENT_SECRET exported (a cluster service
# principal used by no other cluster), and Owner (or Contributor + User Access
# Administrator) on the subscription.
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require az jq curl

: "${ARO_CLIENT_ID:?export ARO_CLIENT_ID (cluster service principal app ID)}"
: "${ARO_CLIENT_SECRET:?export ARO_CLIENT_SECRET (cluster service principal secret)}"
[[ -r "$PULL_SECRET_FILE" ]] || die "pull secret not found at $PULL_SECRET_FILE"
[[ -r "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key not found at $SSH_PUBLIC_KEY_FILE"
export ARO_CLIENT_ID ARO_CLIENT_SECRET

print_outputs() {
  echo "Cluster:   $(output clusterName)"
  echo "Console:   $(output consoleUrl)"
  echo "Client VM: ssh azureuser@$(output clientVmPublicIp)"
  echo "Next:      scripts/02-configure-routing.sh"
}

# main.bicep is deployed once (redeploying the VNet would detach ARO's NSGs).
state="$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.provisioningState -o tsv 2>/dev/null || true)"
if [[ "$state" == Succeeded ]]; then
  log "Already deployed"
  print_outputs
  exit 0
fi

log "Registering resource providers"
for ns in Microsoft.RedHatOpenShift Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.Authorization; do
  az provider register --namespace "$ns" --wait -o none
done

if [[ -z "${ARO_VERSION:-}" ]]; then
  ARO_VERSION="$(az aro get-versions -l "$LOCATION" -o tsv | sort -V | tail -1)"
fi
[[ "$(printf '%s\n' 4.21 "$ARO_VERSION" | sort -V | head -1)" == 4.21 ]] \
  || die "ARO $ARO_VERSION is too old; route advertisements need 4.21 or later"
echo "OpenShift version: $ARO_VERSION"

ARO_CLIENT_OBJECT_ID="$(az ad sp show --id "$ARO_CLIENT_ID" --query id -o tsv)"
ARO_RP_OBJECT_ID="$(az ad sp list --filter "appId eq 'f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875'" --query '[0].id' -o tsv)"
[[ -n "$ARO_RP_OBJECT_ID" ]] || die "Azure Red Hat OpenShift RP service principal not found in this tenant"

if [[ -z "${MY_IP:-}" ]]; then
  MY_IP="$(curl -fsS https://api.ipify.org)/32"
fi
echo "Client VM SSH allowed from: $MY_IP"

if az group show -n "$MANAGED_RESOURCE_GROUP" -o none 2>/dev/null; then
  die "$MANAGED_RESOURCE_GROUP already exists, so a cluster was already started here (deployment state: ${state:-none}). A failed ARO cluster cannot be repaired: run scripts/destroy.sh, then deploy again."
fi

if [[ "${TAG_MANAGED_RG:-true}" == "true" ]]; then
  log "Tagging policy for $MANAGED_RESOURCE_GROUP"
  az deployment sub create -l "$LOCATION" -n "$DEPLOYMENT_NAME-mrg-tag-policy" \
    -f "$REPO_ROOT/infra/managed-rg-tag-policy.bicep" \
    -p managedResourceGroupName="$MANAGED_RESOURCE_GROUP" -o none

  # A new assignment can take up to 30 minutes to take effect. Prove it with a
  # throwaway resource group of the same name, then delete it before ARO needs it.
  echo "Waiting for the policy to take effect (up to 30 minutes)"
  deadline=$((SECONDS + 1800))
  while :; do
    tag="$(az group create -n "$MANAGED_RESOURCE_GROUP" -l "$LOCATION" --query 'tags.SecurityControl' -o tsv)"
    az group delete -n "$MANAGED_RESOURCE_GROUP" --yes
    [[ "$tag" == "Ignore" ]] && break
    ((SECONDS < deadline)) || die "the tagging policy did not take effect within 30 minutes"
    sleep 60
  done
fi

log "Creating resource group $RESOURCE_GROUP"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none \
  --tags Environment=lab Project=arovirt ManagedBy=Bicep Owner=Nirmal SecurityControl=Ignore

log "Deploying infra/main.bicep (60-80 minutes)"
ARO_PULL_SECRET="$(<"$PULL_SECRET_FILE")"
SSH_PUBLIC_KEY="$(<"$SSH_PUBLIC_KEY_FILE")"
export ARO_VERSION MANAGED_RESOURCE_GROUP ARO_PULL_SECRET ARO_CLIENT_OBJECT_ID ARO_RP_OBJECT_ID SSH_PUBLIC_KEY MY_IP
az deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
  -p "$REPO_ROOT/infra/main.bicepparam" -o none

log "Done"
print_outputs
