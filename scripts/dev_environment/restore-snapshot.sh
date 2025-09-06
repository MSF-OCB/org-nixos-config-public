#!/usr/bin/env bash
set -euo pipefail
set -x

az disk create --resource-group msf --name vmDiskRestored --source initial-snapshot
az vm stop -n msf -g msf
az vm update -g msf -n msf --os-disk /subscriptions/1dac1346-e1e1-42dd-a096-a0dc35dd8ec4/resourceGroups/msf/providers/Microsoft.Compute/disks/vmDiskRestored
az vm start -n msf -g msf
