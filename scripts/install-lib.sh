# shellcheck shell=bash

function print_usage() {
  echo "Usage:"
  echo "./$(basename "${0}") -H <hostname of target> -u <SSH username> -s <SSH name> [-p <SSH port>] [-r] [-S]"
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

relaySshProxyJump="tunneller@demo-relay-1.ocb.msf.org:443"
# shellcheck disable=SC2034
readonly relaySshProxyJump

function parse_opts() {
  if [[ $# -eq 0 ]]; then
    exit_usage
  fi

  username=""
  hostname=""
  sshname=""
  sshport=""
  declare -gi userelay=0
  declare -gi addsecrets=1

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

  if ((sshport == 0)); then
    sshport=22
    echo
    echo "Hint: using default SSH port '${sshport}'."
  fi

  # shellcheck disable=SC2034
  readonly username hostname sshname sshport userelay addsecrets
  export username hostname sshname sshport userelay addsecrets

  if [[ -z ${hostname} || -z ${username} || -z ${sshname} || -z ${sshport} ]]; then
    echo
    echo "ERROR: missing mandatory command-line option(s)"
    exit_usage
  fi
}

function generate_tunnel_key() {
  echo
  echo "Generating new tunnel key..."
  # Generate a new tunnel key and have nixos-anywhere upload it to the new root fs
  extra_files="$(mktemp --directory --tmpdir -t extra_files.XXXXXXXX)"
  readonly extra_files
  trap 'rm -rf "${extra_files}"' EXIT
  mkdir --parents "${extra_files}/var/lib/org-nix/"
  ssh-keygen -t ed25519 -C "" -N "" -f "${extra_files}/var/lib/org-nix/id_tunnel"
}

function update_tunnels_json() {
  # Deployment was successful, now we need to add the new tunnel public key to tunnels.json
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
}
