#!/usr/bin/env bash
# Provision a RHEL 9 VMSS to back an Azure DevOps "Azure virtual machine scale
# set agents" (elastic) pool, to reproduce a common self-hosted-agent setup.
#
# This creates ONLY the VMSS in your Azure sandbox. Registering it as an ADO
# agent pool and creating the service connection are portal/CLI steps done AFTER
# this - see README.md. ADO installs and runs the pipeline agent on each node;
# cloud-init.yaml installs PowerShell 7 + Az + az CLI.
#
# COST: this starts real VMs (RHEL PAYG license + compute). Delete the resource
# group when done (see README.md teardown). Keep the size/count small.
#
# Usage:
#   ./provision-vmss.sh <resource-group> <location> [vmss-name] [vm-sku] [instances]
# Example:
#   ./provision-vmss.sh rda-ado-repro-rg eastus rda-rhel-vmss Standard_D2s_v5 2
set -euo pipefail

RG="${1:?resource group required}"
LOC="${2:?location required (e.g. eastus)}"
VMSS="${3:-rda-rhel-vmss}"
SKU="${4:-Standard_D2s_v5}"
INSTANCES="${5:-2}"
IMAGE="RedHat:RHEL:9-lvm-gen2:latest"   # first-party RHEL 9 (PAYG). Free clones:
                                        #   Rocky/Alma via 3rd-party marketplace
                                        #   (needs `az vm image terms accept`).
CLOUD_INIT="$(dirname "$0")/cloud-init.yaml"

echo "Creating resource group '$RG' in '$LOC'..."
az group create -n "$RG" -l "$LOC" -o none

# VMSS settings REQUIRED by ADO elastic pools:
#   --disable-overprovision      : ADO manages instance lifecycle, not the VMSS
#   --upgrade-policy-mode manual  : ADO controls image/agent updates
#   --single-placement-group false: allows scaling past one placement group
#   no autoscale rules            : ADO does the scaling (do NOT add az monitor autoscale)
echo "Creating RHEL 9 VMSS '$VMSS' ($SKU x$INSTANCES)..."
az vmss create \
  --resource-group "$RG" \
  --name "$VMSS" \
  --image "$IMAGE" \
  --vm-sku "$SKU" \
  --instance-count "$INSTANCES" \
  --orchestration-mode Uniform \
  --disable-overprovision \
  --upgrade-policy-mode manual \
  --single-placement-group false \
  --load-balancer '' \
  --admin-username azureuser \
  --generate-ssh-keys \
  --custom-data "$CLOUD_INIT" \
  --tags purpose=ado-agent-repro owner=rda-sandbox \
  -o none

echo
echo "VMSS '$VMSS' created in '$RG'."
echo "Next (see README.md):"
echo "  1. Azure DevOps -> Project settings -> Agent pools -> Add pool ->"
echo "     'Azure virtual machine scale set' -> pick this VMSS -> name it 'rda-rhel-vmss'."
echo "  2. Create an ARM service connection (workload-identity federation preferred)."
echo "  3. Set variables in azure-pipelines.yml and run it."
echo
echo "TEARDOWN when finished:  az group delete -n \"$RG\" --yes --no-wait"
