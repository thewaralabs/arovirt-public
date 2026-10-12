# ARO x86 virtualization lab: guest VMs with routable IPs (no NAT)

This lab runs virtual machines on OpenShift Virtualization on Azure Red Hat OpenShift (ARO) x86 workers and makes them first-class citizens of the Azure network. An ordinary Azure VM reaches each guest at the guest's own IP, and the guests reach the Azure VM the same way. Neither side's address is translated, and there are no user-defined routes, tunnels or network virtual appliances.

How it works:

- The ARO workers run FRR and announce the guest network `10.101.0.0/24` over BGP to **Azure Route Server**.
- Route Server programs that route into the peered client VNet, with the three workers as equal-cost next hops.
- The guests sit on a primary Layer2 **user-defined network**, attached with the **l2bridge** binding, so they own their addresses. A **RouteAdvertisements** object advertises that network, which also turns off OVN's egress SNAT for it.

> **Support boundary.** This is a lab, not a supported ARO configuration. In OpenShift 4.21, Red Hat documents BGP route advertisements for bare-metal clusters only. Enabling IP forwarding on worker NICs in the ARO-managed resource group is outside the normal ARO support model. Use the lab to show how the mechanism works and to gather requirements, not as a production design.

![ARO x86 virtualization lab architecture: the Azure client VM in the peered client VNet reaches OpenShift Virtualization guests fedora-a and fedora-b on the ARO workers at their real 10.101.0.x IPs, with the guest network learned over BGP by Azure Route Server and programmed into the client VNet through gateway transit](docs/images/architecture-2.png)

Route Server is only the control plane (dashed blue lines): the workers advertise the guest network to it over BGP, and it programs that route into the client VNet. Packets (solid purple) go directly between the Azure VM and the guests over the peering, with no NAT.

[SVG](docs/images/architecture-2.svg) |
[Editable Excalidraw source](docs/images/architecture-2.excalidraw) |
[Icon provenance](docs/images/architecture-2.assets/provenance.json) |
[Icon license (GPLv3)](docs/images/architecture-2.assets/LICENSE)



## What gets deployed

| Layer | Resource | Configuration |
|---|---|---|
| ARO network | `arovirt-aro-vnet` `10.0.0.0/20` | `control-plane` `10.0.0.0/23`, `workers` `10.0.2.0/23`, `RouteServerSubnet` `10.0.4.0/26` |
| ARO | `arovirt-aro-<suffix>` | OpenShift 4.21+, public API and ingress, 3 x `Standard_D8s_v5` masters, 3 x `Standard_E8as_v5` workers (AMD x86, nested virtualization, 64 GiB) |
| Routing control plane | Route Server `arovirt-rs` | ASN 65515, BGP endpoints `10.0.4.4` and `10.0.4.5`, branch-to-branch off, one BGP peer per worker (ASN 65001) |
| Client network | `arovirt-client-vnet` `10.50.0.0/16` | Subnet `client` `10.50.1.0/24` with NSG `arovirt-client-nsg`. Peered to the ARO VNet with gateway transit. |
| Test client | VM `arovirt-client` | Ubuntu 24.04, `Standard_D2s_v5`, `10.50.1.4`, public IP for SSH from `MY_IP` only |
| Virtualization | OpenShift Virtualization | `stable` channel; `HyperConverged` with the common boot image import turned off |
| Cluster routing | FRR-K8s | `FRRConfiguration` `route-server`: workers peer with both Route Server instances and accept only `10.50.0.0/16` |
| Guest network | `ClusterUserDefinedNetwork` `arovirt-guests` | Primary Layer2 `10.101.0.0/24`, persistent IPAM, advertised by `RouteAdvertisements` `arovirt-guests` |
| Guests | VMs `fedora-a`, `fedora-b` | Fedora, 2 vCPU, 4 GiB, `l2bridge` binding, one per worker |

Everything is in one resource group (default `arovirt-rg`), plus the resource group that ARO manages (`arovirt-rg-managed`).

## Repository layout

```text
infra/
  main.bicep                    ARO, Route Server, client VNet and VM, peering (deploy once)
  main.bicepparam               parameters, read from environment variables set by the script
  route-server-peers.bicep      one Route Server BGP peer per worker
  managed-rg-tag-policy.bicep   optional: tag the ARO-managed resource group at creation
cluster/
  virtualization-operator.yaml  OpenShift Virtualization operator subscription
  hyperconverged.yaml           HyperConverged instance
  frr-configuration.yaml        BGP peering between the workers and Route Server
  guest-network.yaml            guest namespace and primary Layer2 UDN
  guests.yaml                   two Fedora VMs with l2bridge
  route-advertisements.yaml     advertise the guest network
scripts/
  00-preflight.sh               step 0: read-only readiness check (tools, access, quota, service principal)
  01-deploy-azure.sh            step 1: Azure (60-80 minutes)
  02-configure-routing.sh       step 2: worker NIC IP forwarding and Route Server peers
  03-configure-cluster.sh       step 3: OpenShift configuration and guests
  verify.sh                     read-only end-to-end check
  demo.sh                       one-command live proofs for the demo
  destroy.sh                    delete everything
  common.sh                     shared settings and helpers, sourced by the scripts
docs/
  run-and-demo.md               runbook: prerequisites, deploy, troubleshoot, demo run sheet, teardown
  demo-guide.md                 step-by-step customer demo script
  lessons-learned.md            what went wrong in the original build, and why the lab looks like this
  images/architecture-2.*       architecture diagram: PNG, SVG, Excalidraw source, icon assets and license
  images/architecture.*         earlier architecture diagram, kept for reference
```

## Prerequisites

- An Azure subscription with **Owner** (or Contributor plus User Access Administrator), and quota for about 58 vCPUs in the region: 50 running plus 8 for the ARO bootstrap node. The `Standard_E8as_v5` workers need 24 vCPUs in the EASv5 family.
- Azure CLI, `jq`, `curl`, `ssh` and the OpenShift CLI `oc`.
- A **Red Hat pull secret** from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret). OpenShift Virtualization is installed from the `redhat-operators` catalog, which needs it.
- A **cluster service principal**, used by this cluster only.

  ```bash
  az ad sp create-for-rbac -n "arovirt-cluster-$(date +%Y%m%d)" --skip-assignment
  ```

  Keep the `appId` and `password` in a password manager, not in this repository. The deployment grants the role it needs.

## Deploy

The [runbook](docs/run-and-demo.md) has the details for every step: timings, how to watch progress, what success looks like and troubleshooting.

```bash
cp lab.env.example lab.env              # set RESOURCE_GROUP, LOCATION, file paths, MY_IP
export ARO_CLIENT_ID=<appId>
read -rs -p "ARO client secret: " ARO_CLIENT_SECRET && export ARO_CLIENT_SECRET && echo
az login

scripts/00-preflight.sh                 # read-only: tools, access, quota, service principal
scripts/01-deploy-azure.sh              # Azure: ARO, Route Server, client VM (60-80 min)
scripts/02-configure-routing.sh         # worker NIC IP forwarding, Route Server BGP peers
scripts/03-configure-cluster.sh         # virtualization, BGP, guest network, guests, advertisement
scripts/verify.sh                       # check routing end to end
```

What each step does, and why:

1. **`01-deploy-azure.sh`** registers the resource providers and picks the newest ARO version if `ARO_VERSION` is empty. When `TAG_MANAGED_RG=true`, it first deploys a policy that tags the ARO-managed resource group with `SecurityControl=Ignore`, and waits until that policy takes effect (see [lessons learned](docs/lessons-learned.md#azure-policy-can-break-aro-bootstrap)). It then deploys `infra/main.bicep`. The template builds Route Server first, then the peerings with gateway transit, because the `useRemoteGateways` flag needs Route Server to exist. It builds the ARO cluster last, so nothing else writes to the VNet while ARO installs.
2. **`02-configure-routing.sh`** enables IP forwarding on the worker NICs. Without it, Azure drops packets whose destination or source is a guest IP, because a guest IP is not the NIC's own IP. The NICs are behind the managed resource group's deny assignment, so the script makes this change as the cluster service principal, which the deny assignment exempts. It then adds each worker as a Route Server BGP peer.
3. **`03-configure-cluster.sh`** installs OpenShift Virtualization. It then enables FRR and route advertisements in the cluster network operator, labels the workers as BGP speakers and applies the `FRRConfiguration`, then waits for 2 established sessions per worker. Next it creates the guest network and guests. Advertising a network turns off its egress SNAT, which cuts the guests off from the internet, so the script waits until cloud-init has installed the guest packages before it applies the `RouteAdvertisements`.

Steps 2 and 3 are idempotent, so you can rerun them. Step 1 deploys `main.bicep` only once. Rerunning it after a successful deployment just prints the outputs. If the cluster deployment failed, run `scripts/destroy.sh` and start again, because a failed ARO cluster cannot be repaired.

## Use the lab

```bash
source lab.env
export KUBECONFIG=$PWD/.arovirt/kubeconfig
CLIENT_IP=$(az deployment group show -g "$RESOURCE_GROUP" -n arovirt --query properties.outputs.clientVmPublicIp.value -o tsv)
oc get vmi -n arovirt-guests                        # guest IPs, from 10.101.0.0/24

ssh azureuser@$CLIENT_IP                            # the Azure client VM
ssh -J azureuser@$CLIENT_IP fedora@<guest IP>       # a guest, routed natively through the client VM
```

A quick no-NAT proof: start `python3 -m http.server 5201` on a guest and `curl http://<guest IP>:5201/` from the client VM. The guest's access log shows `10.50.1.4`. Then reverse it: run the server on the client VM and `curl http://10.50.1.4:5201/` from a guest. The client sees the guest's own `10.101.0.x` address, not a worker IP.

`scripts/demo.sh` runs these proofs and the BGP and route checks with one command each (`status`, `bgp`, `routes`, `capture`, `inbound`, `outbound`, `udp`), and `eval "$(scripts/demo.sh env)"` sets the shell variables above. The [run sheet](docs/run-and-demo.md#run-the-demo) uses it.

The [demo guide](docs/demo-guide.md) walks through the full customer demo: the configuration, the BGP and effective-route proof, traffic in both directions with packet captures, and the usual customer questions.

## Operations

- **Worker changes.** IP forwarding and the Route Server peers are tied to the current worker NICs. A new worker gets forwarding off and no peer. After scaling, repair or an upgrade that replaces workers, rerun `02-configure-routing.sh` and `03-configure-cluster.sh`. Remove the Route Server peers of deleted workers with `az network routeserver peering delete`.
- **Guest internet access.** Guests have none after the network is advertised. A production design needs an explicit egress path, which this lab does not provide.
- **MTU.** The guest MTU is 1400, because OVN still uses a Geneve overlay between workers. "No NAT" means no address translation, not no encapsulation.
- **Cost.** ARO (six VMs plus the cluster fee) and Route Server bill by the hour whether or not the guests run. Delete the lab when you are done.

## Delete the lab

```bash
scripts/destroy.sh     # asks you to type the resource group name
```

This deletes the ARO cluster and its managed resource group, the lab resource group and the tagging policy. Delete the cluster service principal separately.

## References

- [OpenShift Virtualization on ARO](https://learn.microsoft.com/azure/openshift/howto-create-openshift-virtualization)
- [Azure Route Server](https://learn.microsoft.com/azure/route-server/overview)
- [OpenShift route advertisements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/advanced_networking/route-advertisements)
- [Primary user-defined networks for virtual machines](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/networking)
