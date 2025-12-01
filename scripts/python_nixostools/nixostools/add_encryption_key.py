import argparse
import secrets

from nixostools import ansible_vault_lib
from nixostools.secret_lib import (
    CONTENT_KEY,
    PATH_KEY,
    SECRETS_KEY,
    SERVERS_KEY,
)


def args_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hostname", dest="hostname", required=True, type=str)
    parser.add_argument("--dry-run", dest="dry_run", action="store_true")
    parser.add_argument(
        "--secrets_file",
        dest="secrets_file",
        required=True,
        type=str,
        help="path to the file where we should store the generated encryption keys",
    )
    parser.add_argument(
        "--ansible_vault_passwd",
        dest="ansible_vault_passwd",
        required=False,
        type=str,
        help="the ansible-vault password, if empty the script will ask for the password",
    )
    parser.add_argument(
        "--key",
        dest="key",
        required=False,
        type=str,
        help="the new key to add",
    )
    parser.add_argument(
        "--recovery_key",
        dest="recovery_key",
        required=False,
        type=str,
        help="the new recovery key to add",
    )
    parser.add_argument(
        "--remove_entries_from",
        dest="remove_entries_from",
        required=False,
        type=str,
        help="file from which we should remove any old encryption keys, if it contains any",
    )
    return parser


def main() -> None:
    args = args_parser().parse_args()

    print(f"Adding the encryption keys for {args.hostname}...")

    if not args.dry_run:
        ansible_vault_passwd = ansible_vault_lib.get_ansible_passwd(
            args.ansible_vault_passwd
        )

    if not args.dry_run:
        try:
            data = ansible_vault_lib.read_vault_file(
                ansible_vault_passwd, args.secrets_file
            )
        except FileNotFoundError:
            data = {SECRETS_KEY: {}}

        if args.remove_entries_from:
            try:
                old_data = ansible_vault_lib.read_vault_file(
                    ansible_vault_passwd, args.remove_entries_from
                )
            except FileNotFoundError:
                old_data = None
        else:
            old_data = None
    else:
        data = {SECRETS_KEY: {}}
        old_data = None

    if not args.key:
        key = secrets.token_hex(64)
    else:
        key = args.key

    if not args.recovery_key:
        recovery_key = secrets.token_hex(64)
    else:
        recovery_key = args.recovery_key

    main_key = f"{args.hostname}-encryption-key"
    recovery_key = f"{args.hostname}-recovery-encryption-key"

    data[SECRETS_KEY][main_key] = {
        PATH_KEY: "keyfile",
        CONTENT_KEY: key,
        SERVERS_KEY: [args.hostname],
    }

    data[SECRETS_KEY][recovery_key] = {
        PATH_KEY: "recovery-keyfile",
        CONTENT_KEY: recovery_key,
        # This key should not be accessible by any server!!
        SERVERS_KEY: [],
    }

    if not args.dry_run:
        ansible_vault_lib.write_vault_file(
            ansible_vault_passwd, args.secrets_file, data
        )
        print(f"Encryption keys for {args.hostname} successfully added.")

        if old_data:
            main_key_removed = old_data.get(SECRETS_KEY, {}).pop(main_key, None)
            recovery_key_removed = old_data.get(SECRETS_KEY, {}).pop(recovery_key, None)
            if main_key_removed or recovery_key_removed:
                ansible_vault_lib.write_vault_file(
                    ansible_vault_passwd, args.remove_entries_from, old_data
                )
                print(f"Old encryption keys for {args.hostname} successfully removed.")
    else:
        print(data)


if __name__ == "__main__":
    main()
