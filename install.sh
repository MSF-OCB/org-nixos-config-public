#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

function print_usage() {
  echo "Usage:"
  echo "./install.sh -H <hostname of target> -u <SSH username> -s <SSH name> [-p <SSH port>] [-r] [-S]"
  echo "Optional arguments:"
  echo "  -s: the SSH name, as specified in your SSH config, or IP address of the target machine"
  echo "      (this option is mandatory unless -r is specified)"
  echo "  -p: the SSH port, will use port 22 unless specified"
  echo "  -r: use the SSH relay to connect to the target machine"
  echo "  -S: don't attempt to add the new disk encryption secrets to the secrets mechanism"
}

function exit_usage() {
  echo
  print_usage
  exit 1
}

function exit_if_missing_arg() {
  if [[ -z ${2:-} ]]; then
    echo
    echo "ERROR: command-line option '-${1}' requires an argument"
    exit_usage
  fi
}

function exit_invalid_arg() {
  echo
  echo "ERROR: argument of command-line option '-${1}' is invalid: '${2}'"
  exit_usage
}

echo "MSF-OCB customised NixOS Linux installation script (nixos-anywhere)"

script_dir="$(cd -- "$(dirname -- "${0}")" && pwd)"
readonly script_dir

relaySshProxyJump="tunneller@sshrelay.ocb.msf.org:443"
readonly relaySshProxyJump

username=""
hostname=""
sshname=""
sshport=""
declare -i userelay=0
declare -i addsecrets=1

if [[ $# -eq 0 ]]; then
  exit_usage
fi

while getopts ':u:H:s:p:rhS' flag; do
  case "${flag}" in
  u)
    if [[ ${OPTARG} =~ ^-. ]]; then
      OPTIND=$((OPTIND - 1))
    else
      username="${OPTARG}"
    fi
    exit_if_missing_arg "${flag}" "${username}"
    ;;
  H)
    if [[ ${OPTARG} =~ ^-. ]]; then
      OPTIND=$((OPTIND - 1))
    else
      hostname="${OPTARG}"
    fi
    exit_if_missing_arg "${flag}" "${hostname}"
    ;;
  s)
    if [[ ${OPTARG} =~ ^-. ]]; then
      OPTIND=$((OPTIND - 1))
    else
      sshname="${OPTARG}"
    fi
    exit_if_missing_arg "${flag}" "${sshname}"
    ;;
  p)
    if [[ ${OPTARG} =~ ^-. ]]; then
      OPTIND=$((OPTIND - 1))
    else
      sshport="${OPTARG}"
    fi
    exit_if_missing_arg "${flag}" "${sshport}"
    if [[ ! ${sshport} =~ ^[0-9]+$ ]] || ((sshport <= 0 || sshport > 65535)); then
      exit_invalid_arg "${flag}" "${sshport}"
    fi
    ;;
  r)
    userelay=1
    ;;
  S)
    addsecrets=0
    ;;
  :)
    echo
    echo "ERROR: invalid command-line option(s)"
    exit_usage
    ;;
  *)
    echo
    echo "ERROR: invalid command-line option '-${OPTARG}'"
    exit_usage
    ;;
  esac
done

if ((userelay)); then
  sshname="localhost"
  echo
  echo "Hint: command-line option '-r' specified to use the SSH relay, setting the SSH name to '${sshname}'."
fi

declare -i sshport="${sshport:-}"
if ((sshport == 0)); then
  sshport=22
  echo
  echo "Hint: using default SSH port '${sshport}'."
fi

readonly username hostname sshname sshport userelay addsecrets

if [[ -z ${hostname} || -z ${username} || -z ${sshname} || -z ${sshport} ]]; then
  echo
  echo "ERROR: missing mandatory command-line option(s)"
  exit_usage
fi

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

echo
echo "Generating new tunnel key..."
# Generate a new tunnel key and have nixos-anywhere upload it to the new root fs
extra_files="$(mktemp --directory --tmpdir -t extra_files.XXXXXXXX)"
readonly extra_files
mkdir --parents "${extra_files}/var/lib/org-nix/"
ssh-keygen -t ed25519 -C "" -N "" -f "${extra_files}/var/lib/org-nix/id_tunnel"

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

# Don't leave the private key behind on this machine
rm -rf "${extra_files}/var/lib/org-nix/id_tunnel"

if ! type -p "jq" >&/dev/null; then
  PATH="${PATH}:$(nix build 'nixpkgs#jq.bin' --print-out-paths)/bin"
  export PATH
fi
jq \
  --arg hostname "${hostname}" \
  --arg pubkey "$(sed -e 's: *$::' "${extra_files}/var/lib/org-nix/id_tunnel.pub")" \
  '.tunnels."per-host".[$hostname].public_key |= $pubkey' \
  <org-config/json/tunnels.d/tunnels.json >org-config/json/tunnels.d/tunnels.json.tmp
mv org-config/json/tunnels.d/tunnels.json.tmp org-config/json/tunnels.d/tunnels.json

echo
echo "New tunnel key, added to 'tunnels.json':"
cat "${extra_files}/var/lib/org-nix/id_tunnel.pub"
echo
echo "This machine will not be able to update itself or to decrypt any secrets"
echo "until you add this key to tunnels.json, and merge the commit into the main branch"

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
