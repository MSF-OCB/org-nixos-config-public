#! /usr/bin/env bash

# for bash 4
# this will be called when a command is entered
# but not found in the user’s path + environment
command_not_found_handle() {

  # TODO: use "command not found" gettext translations

  # taken from http://www.linuxjournal.com/content/bash-command-not-found
  # - do not run when inside Midnight Commander or within a pipe
  if [ -n "${MC_SID-}" ] || ! [ -t 1 ]; then
    echo >&2 "$1: command not found"
    return 127
  fi

  toplevel=nixpkgs # nixpkgs should always be available even in NixOS
  cmd=$1
  attrs=$(@out@/bin/nix-locate --minimal --no-group --type x --type s --top-level --whole-name --at-root "/bin/$cmd")
  len=$(echo -n "$attrs" | grep -c "^")

  case $len in
  0)
    echo >&2 "$cmd: command not found"
    ;;
  1)
    cat >&2 <<EOF
The program '$cmd' is currently not installed. You can run it once with:
  nix shell $toplevel#$attrs -c $cmd ...
EOF
    ;;
  *)
    cat >&2 <<EOF
The program '$cmd' is currently not installed. It is provided by
several packages. You can run it once with:
EOF

    while read -r attr; do
      echo >&2 "  nix shell $toplevel#$attr -c $cmd ..."
    done <<<"$attrs"
    ;;
  esac

  return 127 # command not found should always exit with 127
}

# for zsh...
# we just pass it to the bash handler above
# apparently they work identically
command_not_found_handler() {
  command_not_found_handle "$@"
  return $?
}
