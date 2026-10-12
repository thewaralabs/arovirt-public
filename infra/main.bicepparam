using './main.bicep'

// Values come from environment variables set by scripts/01-deploy-azure.sh, so no
// secret is written to disk or passed on a command line. Every other parameter
// keeps its default from main.bicep.
param openshiftVersion = readEnvironmentVariable('ARO_VERSION')
param managedResourceGroupName = readEnvironmentVariable('MANAGED_RESOURCE_GROUP')
param pullSecret = readEnvironmentVariable('ARO_PULL_SECRET')
param clusterSpClientId = readEnvironmentVariable('ARO_CLIENT_ID')
param clusterSpObjectId = readEnvironmentVariable('ARO_CLIENT_OBJECT_ID')
param clusterSpClientSecret = readEnvironmentVariable('ARO_CLIENT_SECRET')
param aroRpObjectId = readEnvironmentVariable('ARO_RP_OBJECT_ID')
param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY')
param myIp = readEnvironmentVariable('MY_IP')
