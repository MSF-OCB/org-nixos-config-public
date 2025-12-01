#!/usr/bin/env bash
set -euo pipefail
set -x
osDiskId=$(az vm show -g msf -n msf --query "storageProfile.osDisk.managedDisk.id" -o tsv)
az snapshot create -g msf --source "$osDiskId" --name initial-snapshot
