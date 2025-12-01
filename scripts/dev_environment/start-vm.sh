#!/usr/bin/env bash
set -euo pipefail
set -x

vm_name="msf"
img_name="MicrosoftWindowsDesktop:Windows-10:21h1-ent:latest"
location="westeurope"
group="msf"

if ! az group show -n "${group}" &>/dev/null; then
  az group create --name "${group}" --location "${location}"
fi

nsg=$(az network nsg list -g "$group" --query "[?name == 'default-$location'].name|[0]")
if [[ -z $nsg ]]; then
  echo "Creating NSG default-$location"
  az network nsg create -g "$group" -n default-$location >/dev/null
  az network nsg rule create -g "$group" --nsg-name default-$location \
    --priority 1000 \
    --source-address-prefixes "$(curl ifconfig.me)" \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --name "AllowBuilderAnyInbound" \
    --description "Allow remote dev traffic" >/dev/null
fi

vm=$(az vm list -g $group --query "[?name == '$vm_name'].name|[0]")
if [[ -z $vm ]]; then
  az vm create \
    -n "$vm_name" \
    -l "$location" \
    --image "$img_name" \
    --size Standard_D4s_v3 \
    -g "$group" \
    --nsg "default-$location" \
    --admin-username msf \
    --storage-sku Standard_LRS \
    --priority Spot \
    --max-price -1 \
    --eviction-policy Deallocate
fi
az vm start --resource-group "$group" --name "$vm_name" || true
az vm list-ip-addresses -g "$group" -n "$vm_name" --query "[].virtualMachine.network.publicIpAddresses[].ipAddress" -o tsv
