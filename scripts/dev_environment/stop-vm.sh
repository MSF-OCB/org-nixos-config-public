#!/usr/bin/env bash
set -euo pipefail
set -x

vm_name="msf"
group="msf"

az vm deallocate --resource-group "$group" --name "$vm_name" --no-wait
