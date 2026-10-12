#!/usr/bin/env bash
# Step 0: read-only check that you are ready to run step 1. It changes nothing in
# Azure or on this machine, and never prints a secret.
#
# Checks: tools, Azure sign-in and permissions, lab.env and the files it points to,
# the cluster service principal, the ARO version, vCPU quota and VM size
# availability, and that no earlier attempt is in the way.
AROVIRT_READ_ONLY=1
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

# Sizes and counts from the infra/main.bicep defaults. ARO also runs a temporary
# bootstrap VM of the master size during installation.
MASTER_SIZE="Standard_D8s_v5" MASTER_FAMILY="standardDSv5Family"
WORKER_SIZE="Standard_E8as_v5" WORKER_FAMILY="standardEASv5Family"
CLIENT_SIZE="Standard_D2s_v5"
NEED_TOTAL=58      # 3 x 8 masters + 8 bootstrap + 3 x 8 workers + 2 client
NEED_DSV5=34       # 3 x 8 masters + 8 bootstrap + 2 client
NEED_EASV5=24      # 3 x 8 workers
ARO_RP_APP_ID="f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875"

failures=0
warnings=0
pass() { printf '  %s: PASS\n' "$1"; }
warn() { printf '  %s: WARN - %s\n' "$1" "$2"; warnings=$((warnings + 1)); }
fail() { printf '  %s: FAIL - %s\n' "$1" "$2"; failures=$((failures + 1)); }

# Runs az against the lab subscription, without changing your CLI default.
azs() { az "$@" ${SUBSCRIPTION_ID:+--subscription "$SUBSCRIPTION_ID"}; }

quota() { # quota <usage name> <cores needed> <label>; reads $usage
  local free
  free="$(jq -r --arg n "$1" '.[] | select(.name.value == $n) | (.limit | tonumber) - (.currentValue | tonumber)' <<<"$usage")"
  if [[ -z "$free" ]]; then
    warn "$3" "quota $1 not reported in $LOCATION"
  elif ((free >= $2)); then
    pass "$3 ($free free, $2 needed)"
  else
    fail "$3" "$free vCPUs free, $2 needed; request more quota for $1 in $LOCATION"
  fi
}

finish() {
  echo
  if ((failures)); then die "$failures check(s) failed, $warnings warning(s). Fix the failures, then rerun this script."; fi
  echo "Ready: $warnings warning(s). Next: scripts/01-deploy-azure.sh"
  exit 0
}

log "Tools"
for cmd in az oc jq curl ssh ssh-keygen; do
  if command -v "$cmd" >/dev/null; then pass "$cmd"; else fail "$cmd" "not found on PATH"; fi
done
if command -v az >/dev/null && az bicep version >/dev/null 2>&1; then
  pass "bicep ($(az bicep version 2>/dev/null | head -1))"
else
  warn "bicep" "not installed for the Azure CLI; run: az bicep install"
fi
if ! command -v az >/dev/null || ! command -v jq >/dev/null; then finish; fi

log "Azure sign-in"
if ! account="$(azs account show -o json 2>/dev/null)"; then
  fail "az account show" "not signed in, or no access to subscription '${SUBSCRIPTION_ID:-default}'; run: az login"
  finish
fi
jq -r '"  subscription: \(.name) (\(.id))", "  tenant:       \(.tenantId)", "  signed in as: \(.user.name) (\(.user.type))"' <<<"$account"
pass "az account show"
SUB_ID="$(jq -r .id <<<"$account")"
if [[ -n "${SUBSCRIPTION_ID:-}" && "$(az account show --query id -o tsv 2>/dev/null)" != "$SUB_ID" ]]; then
  echo "  note: steps 1-3 run 'az account set' to $SUB_ID, which changes your CLI default subscription"
fi

# Owner, or Contributor plus a role that can create role assignments. Assignments
# through management groups, groups or PIM may not all be visible, so this only warns.
user_name="$(jq -r .user.name <<<"$account")"
if roles="$(az role assignment list --assignee "$user_name" --scope "/subscriptions/$SUB_ID" \
    --include-inherited --include-groups --query '[].roleDefinitionName' -o json 2>/dev/null)"; then
  if jq -e 'index("Owner") or (index("Contributor") and (index("User Access Administrator") or index("Role Based Access Control Administrator")))' <<<"$roles" >/dev/null; then
    pass "subscription roles ($(jq -r 'unique | join(", ")' <<<"$roles"))"
  else
    warn "subscription roles" "found [$(jq -r 'unique | join(", ")' <<<"$roles")]; you need Owner, or Contributor plus User Access Administrator"
  fi
else
  warn "subscription roles" "could not list role assignments for $user_name; make sure you have Owner, or Contributor plus User Access Administrator"
fi

log "lab.env"
echo "  RESOURCE_GROUP=$RESOURCE_GROUP  LOCATION=$LOCATION  managed resource group=$MANAGED_RESOURCE_GROUP"
pass "RESOURCE_GROUP and LOCATION set"

if [[ ! -r "${PULL_SECRET_FILE:-}" ]]; then
  fail "pull secret" "PULL_SECRET_FILE '${PULL_SECRET_FILE:-}' not found; download it from https://console.redhat.com/openshift/install/pull-secret"
elif jq -e '.auths | type == "object"' "$PULL_SECRET_FILE" >/dev/null 2>&1; then
  pass "pull secret ($PULL_SECRET_FILE is valid JSON with auths)"
else
  fail "pull secret" "$PULL_SECRET_FILE is not valid pull secret JSON (expected an 'auths' object)"
fi

if [[ ! -r "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
  fail "SSH public key" "SSH_PUBLIC_KEY_FILE '${SSH_PUBLIC_KEY_FILE:-}' not found"
elif fingerprint="$(ssh-keygen -l -f "$SSH_PUBLIC_KEY_FILE" 2>/dev/null)"; then
  pass "SSH public key ($fingerprint)"
  # BatchMode SSH needs the matching private key, as a file or in ssh-agent.
  if [[ ! -r "${SSH_PUBLIC_KEY_FILE%.pub}" ]] && ! ssh-add -L 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$SSH_PUBLIC_KEY_FILE")"; then
    warn "SSH private key" "no ${SSH_PUBLIC_KEY_FILE%.pub} and the key is not in ssh-agent; SSH to the client VM and guests will fail"
  fi
else
  fail "SSH public key" "$SSH_PUBLIC_KEY_FILE is not a valid SSH public key"
fi

if [[ -z "${MY_IP:-}" ]]; then
  if detected="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)"; then
    pass "MY_IP (empty, so step 1 will allow SSH from $detected/32)"
  else
    warn "MY_IP" "empty, and your public IP could not be detected; set MY_IP in lab.env"
  fi
elif [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  pass "MY_IP ($MY_IP)"
else
  fail "MY_IP" "'$MY_IP' is not an IPv4 CIDR such as 203.0.113.10/32"
fi

log "Cluster service principal"
if [[ -z "${ARO_CLIENT_ID:-}" ]]; then
  fail "ARO_CLIENT_ID" "not exported; create a new service principal and export ARO_CLIENT_ID and ARO_CLIENT_SECRET"
else
  pass "ARO_CLIENT_ID set ($ARO_CLIENT_ID)"
  if sp_name="$(az ad sp show --id "$ARO_CLIENT_ID" --query displayName -o tsv 2>/dev/null)"; then
    pass "service principal exists ($sp_name)"
  else
    fail "service principal" "no service principal with app ID $ARO_CLIENT_ID in this tenant"
  fi
  # A client ID still held by another cluster, even a failed one, causes DuplicateClientID.
  if clusters="$(azs aro list --query "[?servicePrincipalProfile.clientId=='$ARO_CLIENT_ID'].{name:name, rg:resourceGroup}" -o json 2>/dev/null)"; then
    others="$(jq -r --arg rg "$RESOURCE_GROUP" '[.[] | select(.rg | ascii_downcase != ($rg | ascii_downcase)) | "\(.rg)/\(.name)"] | join(", ")' <<<"$clusters")"
    if [[ -n "$others" ]]; then
      warn "service principal not in use" "already used by ARO cluster $others; step 1 would fail with DuplicateClientID. Create a new service principal."
    elif [[ "$(jq length <<<"$clusters")" -gt 0 ]]; then
      pass "service principal used only by this lab's cluster ($(jq -r '.[0].name' <<<"$clusters"))"
    else
      pass "service principal not used by any ARO cluster in this subscription"
    fi
  else
    warn "service principal not in use" "could not list ARO clusters (is Microsoft.RedHatOpenShift registered?)"
  fi
fi
if [[ -n "${ARO_CLIENT_SECRET:-}" ]]; then
  pass "ARO_CLIENT_SECRET set (not shown)"
else
  fail "ARO_CLIENT_SECRET" "not exported"
fi
if [[ -n "$(az ad sp list --filter "appId eq '$ARO_RP_APP_ID'" --query '[0].id' -o tsv 2>/dev/null)" ]]; then
  pass "Azure Red Hat OpenShift RP service principal present in the tenant"
else
  warn "Azure Red Hat OpenShift RP service principal" "not found; step 1 registers Microsoft.RedHatOpenShift, which should create it"
fi

log "OpenShift version in $LOCATION"
if versions="$(azs aro get-versions -l "$LOCATION" -o tsv 2>/dev/null)" && [[ -n "$versions" ]]; then
  version="${ARO_VERSION:-$(sort -V <<<"$versions" | tail -1)}"
  if ! grep -qxF "$version" <<<"$versions"; then
    fail "ARO_VERSION" "$version is not offered in $LOCATION; offered: $(sort -V <<<"$versions" | tr '\n' ' ')"
  elif [[ "$(printf '%s\n' 4.21 "$version" | sort -V | head -1)" != 4.21 ]]; then
    fail "ARO version" "$version is older than 4.21, which route advertisements need"
  else
    pass "ARO version $version"
  fi
else
  warn "ARO version" "could not list versions in $LOCATION (step 1 registers Microsoft.RedHatOpenShift; rerun this check afterwards)"
fi

log "Earlier attempts"
state="$(azs deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query properties.provisioningState -o tsv 2>/dev/null || true)"
deployed=false
if [[ "$state" == Succeeded ]]; then
  deployed=true
  pass "resource group $RESOURCE_GROUP (already deployed; step 1 only prints its outputs)"
elif azs group show -n "$RESOURCE_GROUP" -o none 2>/dev/null; then
  warn "resource group $RESOURCE_GROUP" "already exists (deployment state: ${state:-none}). Step 1 deploys into it. If a previous attempt failed, run scripts/destroy.sh first."
else
  pass "resource group $RESOURCE_GROUP does not exist yet"
fi
if ! azs group show -n "$MANAGED_RESOURCE_GROUP" -o none 2>/dev/null; then
  pass "managed resource group $MANAGED_RESOURCE_GROUP does not exist yet"
elif [[ "$deployed" == true ]]; then
  pass "managed resource group $MANAGED_RESOURCE_GROUP belongs to the deployed cluster"
else
  fail "managed resource group $MANAGED_RESOURCE_GROUP" "already exists, so step 1 will refuse to start. A failed ARO cluster cannot be repaired: run scripts/destroy.sh (and delete the group with 'az group delete -n $MANAGED_RESOURCE_GROUP' if no cluster owns it), then use a new service principal."
fi

log "vCPU quota and VM sizes in $LOCATION"
if [[ "$deployed" == true ]]; then
  echo "  skipped: the lab is already deployed"
elif usage="$(azs vm list-usage -l "$LOCATION" -o json 2>/dev/null)"; then
  quota cores "$NEED_TOTAL" "total regional vCPUs"
  quota "$MASTER_FAMILY" "$NEED_DSV5" "DSv5 family vCPUs (masters, bootstrap, client VM)"
  quota "$WORKER_FAMILY" "$NEED_EASV5" "EASv5 family vCPUs (workers)"
else
  warn "vCPU quota" "could not read usage in $LOCATION"
fi
if skus="$(azs vm list-skus -l "$LOCATION" --resource-type virtualMachines -o json 2>/dev/null)"; then
  for size in "$MASTER_SIZE" "$WORKER_SIZE" "$CLIENT_SIZE"; do
    sku="$(jq -c --arg s "$size" '[.[] | select(.name == $s)][0]' <<<"$skus")"
    if [[ "$sku" == null ]]; then
      fail "$size" "not offered in $LOCATION"
    elif jq -e 'any(.restrictions[]; .type == "Location")' <<<"$sku" >/dev/null; then
      fail "$size" "not available to this subscription in $LOCATION: $(jq -r '[.restrictions[].reasonCode] | unique | join(", ")' <<<"$sku")"
    elif jq -e '.restrictions | length > 0' <<<"$sku" >/dev/null; then
      warn "$size" "restricted in zones $(jq -r '[.restrictions[].restrictionInfo.zones[]?] | unique | join(", ")' <<<"$sku") of $LOCATION; placement may fail"
    else
      pass "$size available"
    fi
  done
else
  warn "VM sizes" "could not list VM sizes in $LOCATION"
fi

finish
