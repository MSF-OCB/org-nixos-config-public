#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

function print_usage() {
  echo "Usage:"
  echo "./install-ubuntu.sh -H <hostname of target> -u <SSH username> -s <SSH name> [-p <SSH port>] [-r]"
  echo "Optional arguments:"
  echo "  -s: the SSH name, as specified in your SSH config, or IP address of the target machine"
  echo "      (this option is mandatory unless -r is specified)"
  echo "  -p: the SSH port, will use port 22 unless specified"
  echo "  -r: use the SSH relay to connect to the target machine"
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

echo "System-manager installation script for Ubuntu hosts"

script_dir="$(cd -- "$(dirname -- "${0}")" && pwd)"
readonly script_dir

relaySshProxyJump="tunneller@demo-relay-1.ocb.msf.org:443"
readonly relaySshProxyJump

username=""
hostname=""
sshname=""
sshport=""
declare -i userelay=0

if [[ $# -eq 0 ]]; then
  exit_usage
fi

while getopts ':u:H:s:p:rh' flag; do
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

readonly username hostname sshname sshport userelay

if [[ -z ${hostname} || -z ${username} || -z ${sshname} || -z ${sshport} ]]; then
  echo
  echo "ERROR: missing mandatory command-line option(s)"
  exit_usage
fi

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

echo
echo "Generating new tunnel key..."
tunnel_key_dir="$(mktemp --directory --tmpdir -t tunnel_key.XXXXXXXX)"
readonly tunnel_key_dir
ssh-keygen -t ed25519 -C "" -N "" -f "${tunnel_key_dir}/id_tunnel"

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
scp "${scp_opts[@]}" "${tunnel_key_dir}/id_tunnel" "${ssh_target}:/tmp/id_tunnel"
ssh "${ssh_opts[@]}" "${ssh_target}" "sudo mv /tmp/id_tunnel /var/lib/org-nix/id_tunnel && sudo chown root:root /var/lib/org-nix/id_tunnel && sudo chmod 600 /var/lib/org-nix/id_tunnel"

# Don't leave the private key behind on this machine
rm -f "${tunnel_key_dir}/id_tunnel"

echo
echo "Deploying system-manager configuration for '${hostname}'..."
system-manager switch --flake ".#${hostname}" --target-host "${ssh_target}"

# Update tunnels.json with the new public key
if ! type -p "jq" >&/dev/null; then
  PATH="${PATH}:$(nix build 'nixpkgs#jq.bin' --print-out-paths)/bin"
  export PATH
fi
jq \
  --arg hostname "${hostname}" \
  --arg pubkey "$(sed -e 's: *$::' "${tunnel_key_dir}/id_tunnel.pub")" \
  '.tunnels."per-host".[$hostname].public_key |= $pubkey' \
  <org-config/json/tunnels.d/tunnels.json >org-config/json/tunnels.d/tunnels.json.tmp
mv org-config/json/tunnels.d/tunnels.json.tmp org-config/json/tunnels.d/tunnels.json

echo
echo "New tunnel key, added to 'tunnels.json':"
cat "${tunnel_key_dir}/id_tunnel.pub"

# Clean up remaining public key
rm -rf "${tunnel_key_dir}"

echo
echo "This machine will not be able to establish reverse tunnels"
echo "until you commit tunnels.json and merge the commit into the main branch."

echo
echo "All done"
exit 0
