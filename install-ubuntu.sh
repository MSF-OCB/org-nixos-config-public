#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=scripts/install-lib.sh
source "${script_dir}/scripts/install-lib.sh"

echo "System-manager installation script for Ubuntu hosts"

parse_opts "$@"

# Verify that the hostname corresponds to an Ubuntu host in our config
echo
echo "Verifying that '${hostname}' is a valid Ubuntu host..."
if [[ ! -f "${script_dir}/org-config/hosts/ubuntu/${hostname}.nix" ]]; then
  echo
  echo "ERROR: No Ubuntu host configuration found for '${hostname}'."
  echo "       Expected file: org-config/hosts/ubuntu/${hostname}.nix"
  exit 1
fi
echo "Done"

# Build SSH options (scp uses -P for port, ssh uses -p)
ssh_common_opts=(-o "StrictHostKeyChecking=accept-new")
if ((userelay)); then
  ssh_common_opts+=(-o "ProxyJump=${relaySshProxyJump}")
fi
ssh_opts=("${ssh_common_opts[@]}" -p "${sshport}")
scp_opts=("${ssh_common_opts[@]}" -P "${sshport}")

ssh_target="${username}@${sshname}"

generate_tunnel_key

echo
echo "Checking if Nix is installed on ${ssh_target}..."
# shellcheck disable=SC2029
if ! ssh "${ssh_opts[@]}" "${ssh_target}" "command -v nix-store >/dev/null 2>&1"; then
  echo "Nix is not installed on the remote host. Installing..."
  ssh "${ssh_opts[@]}" "${ssh_target}" "curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm"
  echo "Nix installed successfully."
else
  echo "Nix is already installed."
fi

echo
echo "Uploading tunnel key to ${ssh_target}..."
ssh "${ssh_opts[@]}" "${ssh_target}" "sudo mkdir -p /var/lib/org-nix && sudo chown root:root /var/lib/org-nix && sudo chmod 755 /var/lib/org-nix"
scp "${scp_opts[@]}" "${extra_files}/var/lib/org-nix/id_tunnel" "${ssh_target}:/tmp/id_tunnel"
ssh "${ssh_opts[@]}" "${ssh_target}" "sudo mv /tmp/id_tunnel /var/lib/org-nix/id_tunnel && sudo chown root:root /var/lib/org-nix/id_tunnel && sudo chmod 600 /var/lib/org-nix/id_tunnel"

# Don't leave the private key behind on this machine
rm -f "${extra_files}/var/lib/org-nix/id_tunnel"

echo
echo "Deploying system-manager configuration for '${hostname}'..."
system-manager switch --flake ".#${hostname}" --target-host "${ssh_target}"

update_tunnels_json

# Clean up remaining files
rm -rf "${extra_files}"

echo
echo "All done"
exit 0
