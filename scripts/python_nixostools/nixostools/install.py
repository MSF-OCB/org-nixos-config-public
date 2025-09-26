import argparse
import json
import logging
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path
from textwrap import dedent

from nixostools import sops_yaml

SSH_RELAY_HOST = "tunneller@demo-relay-1.ocb.msf.org:443"
sops_config = sops_yaml.SopsYaml(Path("org-config/.sops.yaml"))

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("nixostools/install")


def create_parser():
    parser = argparse.ArgumentParser(
        description="NixOS Installation Script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=dedent("""\
        Examples:
            install -H myhost -u myuser -s myserver
            install -H myhost -u myuser -s myserver -p 2222
            install -H myhost -u myuser -r
        """),
        add_help=True,
    )
    parser.add_argument("-H", "--host", required=True, help="hostname of target")
    parser.add_argument("-u", "--user", required=True, help="SSH username")
    parser.add_argument(
        "-s",
        "--ssh-host",
        help="the SSH host name, as specified in your SSH config (mandatory unless -r is specified)",
    )
    parser.add_argument(
        "-p", "--ssh-port", type=int, default=22, help="the SSH port (default: 22)"
    )
    parser.add_argument(
        "-r",
        "--use-relay",
        action="store_true",
        help="use the SSH relay to connect to the target machine",
    )
    parser.add_argument(
        "-S",
        "--no-add-secrets",
        action="store_true",
        help="don't attempt to add the new disk encryption secrets to the secrets mechanism",
    )
    return parser


def validate_args(args):
    if args.ssh_port <= 0 or args.ssh_port > 65535:
        logger.fatal("SSH port must be between 1 and 65535")
        sys.exit(1)
    if args.use_relay:
        args.ssh_host = "localhost"
        logger.info(
            f"command-line option '-r/--use-relay' specified to use the SSH relay, setting the SSH host to '{args.ssh_host}'."
        )
    elif not args.ssh_host:
        logger.fatal(
            "missing mandatory command-line option '-s/--sshname' (required unless -r is specified)"
        )
        sys.exit(1)
    return args


def generate_disk_encryption_key(file_path):
    """
    Generate a cryptographically secure 64-byte (512-bit) hex string.
    Returns a 128-character hex string (2 hex chars per byte).
    """
    with open(file_path, "w") as f:
        f.write(secrets.token_bytes(64).hex())


def generate_tunnel_key(file_path):
    """
    Generate a dedicated SSH keys for tunnels.
    This is included for backwards-compatibility as it was historically used to decrypt secrets.
    After the migration to sops-nix has completed, tunnel ssh keys could just be managed with that"
    """
    file_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-C", "", "-N", "", f"-f{file_path}"],
        check=True,
    )


def add_tunnel_key(tunnels_json_path, host, tunnel_public_key_path):
    """
    Add the generated tunnel key to our vault. This was/is used as the cryptographic
    identity of the host before the sops-nix migration and therefore
    needed to be added during installation.
    Could probably be moved to a normal sops-nix secret once thats done.
    """
    with open(tunnels_json_path) as f:
        tunnel_json = json.load(f)
    with open(tunnel_public_key_path) as f:
        tunnel_public_key = f.read().strip()

    host_configs = tunnel_json["tunnels"]["per-host"]
    if host not in host_configs:
        host_configs[host] = dict()
    host_configs[host]["public_key"] = tunnel_public_key
    with open(tunnels_json_path, "w") as f:
        tunnel_json = json.dump(tunnel_json, f, indent=2)
    logging.info(
        dedent(f"""\
    New tunnel key, added to 'tunnels.json':"
    {tunnel_public_key}

    This machine will not be able to update itself or to decrypt any secrets
    until you add this key to tunnels.json, and merge the commit into the main branch
    """)
    )


def generate_age_identity(file_path):
    """
    Generate a dedicated age key pair for use with sops-nix.
    This replaces the tunnel ssh key above to decouple secret management and ssh keys.
    """
    file_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["age-keygen", "-o", file_path], check=True, capture_output=True, text=True
    )
    public_key = proc.stderr.strip().split(" ")[-1]
    logger.info(f"Pre-generated age identity for sops-nix in {file_path}: {public_key}")
    return public_key


def check_host_boot_mode(host):
    logger.info(
        f"Evaluating NixOS configuration of {host}  to check that it uses a GPT disk layout..."
    )
    proc = subprocess.run(
        ["nix", "eval", f".#nixosConfigurations.{host}.config.settings.system.isMbr"],
        check=True,
        text=True,
        capture_output=True,
    )
    if not proc.stdout.strip() == "false":
        logger.fatal(
            "The specified host is configured to use an MBR disk layout, but this is not supported by this installer. Please check settings.system.isMbr."
        )
        sys.exit(1)


def run_nixos_anywhere(args, key_file_path, recovery_key_file_path, extra_files_path):
    """
    Actually run the installation against the remote host by shelling out
    to NixOS anywhere
    """

    relay_options = (
        ["--ssh-option", f"ProxyJump={SSH_RELAY_HOST}"] if args.use_relay else []
    )
    subprocess.run(
        [
            "nix",
            "run",
            "github:nix-community/nixos-anywhere#nixos-anywhere",
            "--",
            "--print-build-logs",
            "--ssh-port",
            str(args.ssh_port),
            *relay_options,
            "--flake",
            f".#{args.host}",
            "--disk-encryption-keys",
            "/run/.secrets/keyfile",
            key_file_path,
            "--disk-encryption-keys",
            "/run/.secrets/rescue-keyfile",
            recovery_key_file_path,
            "--extra-files",
            extra_files_path,
            f"{args.user}@{args.ssh_host}",
        ],
        check=True,
    )


def add_legacy_secrets(
    host,
    key_file_path,
    recovery_key_file_path,
    secrets_master_file,
    secrets_master_file_old,
):
    """
    Calls nixostools/add_encryption_key" to add hosts disk encryption keys
    to ansible-vault. Can be replaced after sops-nix migration.
    """
    with open(key_file_path) as k, open(recovery_key_file_path) as r:
        key = k.read()
        recovery_key = r.read()

    subprocess.run(
        [
            "nix",
            "shell",
            ".#nixostools",
            "--command",
            "add_encryption_key",
            "--hostname",
            host,
            "--secrets_file",
            secrets_master_file,
            "--remove_entries_from",
            secrets_master_file_old,
            "--key",
            key,
            "--recovery_key",
            recovery_key,
        ],
        check=True,
        text=True,
    )

    logger.info(
        dedent("""\
        The new encryption keys were added to legacy secrets.
        This machine will not be able to unlock its encrypted partition until
        you commit the new secrets, merge the commit into the main branch
        and update this server's config.
        """)
    )


def main():
    parser = create_parser()
    args = parser.parse_args()
    args = validate_args(args)

    check_host_boot_mode(args.host)

    secrets_master_file = Path(
        f"org-config/secrets/master/encryption-keys/{args.host}_encryption-secrets.yml"
    )
    secrets_master_file_old = Path(
        "org-config/secrets/master/nixos_encryption-secrets.yml"
    )

    with tempfile.TemporaryDirectory(
        prefix=f"{args.host}_keys", delete=True
    ) as temp_dir:
        temp_dir = Path(temp_dir)
        key_file_path = temp_dir / "keyfile"
        recovery_key_file_path = temp_dir / "recovery_keyfile"
        extra_files_path = temp_dir / "extra_files"
        age_key_path = extra_files_path / "var/lib/host-identity.txt"
        tunnel_key_path = extra_files_path / "var/lib/org-nix/id_tunnel"
        tunnel_public_key_path = tunnel_key_path.with_suffix(".pub")

        generate_disk_encryption_key(key_file_path)
        generate_disk_encryption_key(recovery_key_file_path)
        generate_tunnel_key(tunnel_key_path)

        age_public_key = generate_age_identity(age_key_path)
        age_key_name = f"host_{args.host}"
        sops_config.set_key(age_key_name, age_public_key)
        sops_config.set_creation_rule(
            f"^secrets/hosts/{args.host}\\.yaml$", [age_key_name]
        )
        sops_config.save()

        run_nixos_anywhere(
            args,
            key_file_path,
            recovery_key_file_path,
            extra_files_path,
        )

        add_tunnel_key(
            Path("org-config/json/tunnels.d/tunnels.json"),
            args.host,
            tunnel_public_key_path,
        )

        if args.no_add_secrets:
            logger.info("Skipped adding new encryption keys to legacy secrets")
        else:
            add_legacy_secrets(
                args.host,
                key_file_path,
                recovery_key_file_path,
                secrets_master_file,
                secrets_master_file_old,
            )


if __name__ == "__main__":
    main()
