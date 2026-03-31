#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=scripts/install-lib.sh
source "${script_dir}/scripts/install-lib.sh"

echo "NixOS Linux installation script (nixos-anywhere)"

parse_opts "$@"

encryption_secrets_master_file="${script_dir}/org-config/secrets/master/encryption-keys/${hostname}_encryption-secrets.yml"
readonly encryption_secrets_master_file
old_encryption_secrets_master_file="${script_dir}/org-config/secrets/master/nixos_encryption-secrets.yml"
readonly old_encryption_secrets_master_file

echo
echo "Evaluating the hosts configuration to check that it uses a GPT disk layout..."
if [[ "$(nix eval .#nixosConfigurations."${hostname}".config.settings.system.isMbr)" == "false" ]]; then
  echo "Done"
else
  echo
  echo "ERROR: The specified host is configured to use an MBR disk layout, but this is not supported by this installer."
  echo "       Please set 'settings.system.isMbr' to 'false' and try again."
  exit 1
fi

echo
echo "Generating new encryption keys..."
# Generate 64 byte (512 bit) hex strings (2 hex chars per byte) for the encryption keys
keyfile="$(mktemp --tmpdir -t keyfile.XXXXXXXX)"
readonly keyfile
recovery_keyfile="$(mktemp --tmpdir -t keyfile.XXXXXXXX)"
readonly recovery_keyfile
(
  # tr exits uncleanly below, because we simply close it's output stream,
  # so we don't want pipefail here
  set +o pipefail
  tr -dc 'A-F0-9' </dev/urandom | head -c$((64 * 2)) >"${keyfile}"
  tr -dc 'A-F0-9' </dev/urandom | head -c$((64 * 2)) >"${recovery_keyfile}"
)

generate_tunnel_key

echo
echo "Running nixos-anywhere..."
if ((userelay)); then
  nix run 'github:nix-community/nixos-anywhere#nixos-anywhere' -- \
    --print-build-logs \
    --ssh-port "${sshport}" \
    --ssh-option "ProxyJump=${relaySshProxyJump}" \
    --flake ".#${hostname}" \
    --disk-encryption-keys /run/.secrets/keyfile "${keyfile}" \
    --disk-encryption-keys /run/.secrets/rescue-keyfile "${recovery_keyfile}" \
    --extra-files "$extra_files" \
    "${username}@${sshname}"
else
  nix run 'github:nix-community/nixos-anywhere#nixos-anywhere' -- \
    --print-build-logs \
    --ssh-port "${sshport}" \
    --flake ".#${hostname}" \
    --disk-encryption-keys /run/.secrets/keyfile "${keyfile}" \
    --disk-encryption-keys /run/.secrets/rescue-keyfile "${recovery_keyfile}" \
    --extra-files "$extra_files" \
    "${username}@${sshname}"
fi

update_tunnels_json

echo
if ((addsecrets)); then
  echo "Adding the new encryption keys to the secrets..."
  nix shell ".#nixostools" \
    --command add_encryption_key \
    --hostname "${hostname}" \
    --secrets_file "${encryption_secrets_master_file}" \
    --key "$(<"${keyfile}")" \
    --recovery_key "$(<"${recovery_keyfile}")" \
    --remove_entries_from "${old_encryption_secrets_master_file}"
  echo
  echo "The new encryption keys were added to the secrets."
  echo "This machine will not be able to unlock its encrypted partition until"
  echo "you commit the new secrets, merge the commit into the main branch"
  echo "and update this server's config."
else
  echo "Skipped adding the new encryption keys to the secrets"
fi
echo

echo
echo "All done"
exit 0
