#!/usr/bin/env bash
# Spawn a new dev environment
#
# Usage: ./dev.sh [<command> [...<args>]]
set -euo pipefail

# Run in the current directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# Configure Nix for the project
export NIX_USER_CONF_FILES=$PWD/nix/nix.conf

# Build the devshell
out=$(nix build --no-link --print-out-paths .#devShells.x86_64-linux.default)

# Set PRJ_ROOT for devshell
export PRJ_ROOT=$PWD

# Run the command inside of a pure nix-shell
exec "$out/entrypoint" "$@"
