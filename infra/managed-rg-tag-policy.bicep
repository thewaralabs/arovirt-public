// Optional. Appends SecurityControl=Ignore to the ARO-managed resource group when ARO
// creates it.
//
// Why: in subscriptions with an inherited policy that disables shared-key access on
// storage accounts, ARO bootstrap fails with KeyBasedAuthenticationNotPermitted. The
// tag exempts the managed resource group, but only if it is present at creation:
// tagging afterwards is blocked by the deny assignment, and a failed cluster cannot be
// repaired, only recreated.
targetScope = 'subscription'

@description('The exact managed resource group name passed to main.bicep.')
param managedResourceGroupName string

var policyName = 'arovirt-mrg-tag-${uniqueString(subscription().id, managedResourceGroupName)}'

resource definition 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: policyName
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'arovirt: tag ARO managed resource group ${managedResourceGroupName}'
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            field: 'name'
            equals: managedResourceGroupName
          }
          {
            field: 'tags[SecurityControl]'
            exists: 'false'
          }
        ]
      }
      then: {
        effect: 'append'
        details: [
          {
            field: 'tags[SecurityControl]'
            value: 'Ignore'
          }
        ]
      }
    }
  }
}

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: policyName
  properties: {
    displayName: definition.properties.displayName
    policyDefinitionId: definition.id
  }
}

output policyName string = policyName
