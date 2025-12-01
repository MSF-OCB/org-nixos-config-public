#!/usr/bin/env bash
set -euo pipefail
set -x
vm_name="msf"
group="msf"
echo "Configure VM basic settings"
az vm run-command invoke --resource-group "$group" --name "$vm_name" --command-id "RunPowerShellScript" --scripts "@settings.ps1"
echo "Install chocolatey and dependencies"
az vm run-command invoke --resource-group "$group" --name "$vm_name" --command-id "RunPowerShellScript" --scripts "@chocolatey.ps1"
echo "Configure VSCode"
az vm run-command invoke --resource-group "$group" --name "$vm_name" --command-id "RunPowerShellScript" --scripts "@vscode.ps1"
echo "Install WSL2"
az vm run-command invoke --resource-group "$group" --name "$vm_name" --command-id "RunPowerShellScript" --scripts "@wsl2.ps1"
echo "Install Hyper-V"
az vm run-command invoke --resource-group "$group" --name "$vm_name" --command-id "RunPowerShellScript" --scripts "@hyperv.ps1"
