#! /usr/bin/env bash

set -eou pipefail

keyfile="${1-}"

if [ -z "${keyfile}" ]; then
  echo "ERROR: please provide the SSH private key file as parameter."
  exit 1
fi

iso_path="$(nix build --no-link --json '.#rescue-iso-img' | jq --raw-output '.[0].outputs.out')"

for iso in "${iso_path}"/iso/*; do
  outpath="./$(basename "${iso}")"

  if [ -f "${outpath}" ]; then
    rm --force "${outpath}"
  fi

  # Add the key file to the ISO, it will appear in the NixOS system as /iso/id_tunnel
  xorriso \
    -indev "${iso}" \
    -outdev "${outpath}" \
    -boot_image replay replay \
    -map "${keyfile}" id_tunnel

  echo -e "Wrote ${outpath}"
done
