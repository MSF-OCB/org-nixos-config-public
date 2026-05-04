#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

script_dir="$(dirname "$(realpath "$0")")"
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

# Build SSH options
ssh_common_opts=(-o "StrictHostKeyChecking=accept-new")
if ((userelay)); then
  ssh_common_opts+=(-o "ProxyJump=${relaySshProxyJump}")
fi
ssh_opts=("${ssh_common_opts[@]}" -p "${sshport}")

# With -w, prompt once for the sudo password to install a NOPASSWD sudoers
# fragment, then run everything else silently.
# Without -w, assume passwordless sudo is already configured.
ssh_bootstrap_opts=("${ssh_opts[@]}")
sm_sudo_opts=()
if ((sudopassword)); then
  ssh_bootstrap_opts+=(-t)
  sm_sudo_opts=(--sudo)
fi

# Build --ssh-option flags for system-manager from ssh_opts
sm_ssh_opts=()
for opt in "${ssh_opts[@]}"; do
  sm_ssh_opts+=(--ssh-option "${opt}")
done

ssh_target="${username}@${sshname}"

generate_tunnel_key

if ((sudopassword)); then
  nopasswd_file="/etc/sudoers.d/99-install-${username}"
  readonly nopasswd_file
  # Chain onto generate_tunnel_key's tmpdir-cleanup trap so both run on exit.
  # shellcheck disable=SC2064
  trap "echo; echo 'Removing ${nopasswd_file} from target...'; ssh \"\${ssh_opts[@]}\" \"\${ssh_target}\" 'sudo rm -v -f ${nopasswd_file}' || echo \"WARNING: remote cleanup failed; please remove ${nopasswd_file} on the target manually\"; rm -rf \"\${extra_files}\"" EXIT
  echo
  echo "Installing temporary NOPASSWD sudoers fragment at ${nopasswd_file}..."
  # shellcheck disable=SC2029
  ssh "${ssh_bootstrap_opts[@]}" "${ssh_target}" "echo '${username} ALL=(ALL) NOPASSWD: ALL' | sudo tee ${nopasswd_file} >/dev/null && sudo chmod 0440 ${nopasswd_file}"
fi

echo
echo "Checking if Nix is installed on ${ssh_target}..."
# shellcheck disable=SC2029
if ! ssh "${ssh_opts[@]}" "${ssh_target}" "command -v nix-store >/dev/null 2>&1"; then
  echo "Nix is not installed on the remote host. Installing..."
  ssh "${ssh_opts[@]}" "${ssh_target}" "curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm --extra-conf 'extra-trusted-users = ${username}'"
  echo "Nix installed successfully."
else
  echo "Nix is already installed."
fi

echo
echo "Uploading tunnel key to ${ssh_target}..."
ssh "${ssh_opts[@]}" "${ssh_target}" "cat > /tmp/id_tunnel" <"${extra_files}/var/lib/org-nix/id_tunnel"
ssh "${ssh_opts[@]}" "${ssh_target}" "sudo bash -c 'mkdir -p /var/lib/org-nix && chown root:root /var/lib/org-nix && chmod 755 /var/lib/org-nix && mv /tmp/id_tunnel /var/lib/org-nix/id_tunnel && chown root:root /var/lib/org-nix/id_tunnel && chmod 600 /var/lib/org-nix/id_tunnel'"

if ((sudopassword)); then
  # Remove the NOPASSWD fragment now, while our ssh login still works.
  # system-manager's new sshd only honors /etc/ssh/authorized_keys.d/%u
  # (no ~/.ssh/authorized_keys), so the bootstrap user will get
  # "Permission denied (publickey)" on any ssh attempt after activation.
  echo
  echo "Removing temporary NOPASSWD sudoers fragment at ${nopasswd_file}..."
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${ssh_target}" "sudo rm -v -f ${nopasswd_file}"
  sm_sudo_opts+=(--ask-sudo-password)
  trap 'rm -rf "${extra_files}"' EXIT
fi

echo
echo "Deploying system-manager configuration for '${hostname}'..."
system-manager switch --flake ".#${hostname}" --target-host "${ssh_target}" "${sm_sudo_opts[@]}" "${sm_ssh_opts[@]}"

update_tunnels_json

echo
echo "All done"
exit 0
