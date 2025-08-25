import argparse
import dataclasses
import glob
import os
import traceback
from dataclasses import dataclass
from functools import reduce
from typing import Any, Callable, Iterable, List, Mapping

import yaml
from nacl.public import PublicKey

from nixostools import ansible_vault_lib, ocb_nixos_lib, secret_lib
from nixostools.secret_lib import (
    CONTENT_KEY,
    DEFAULT_EXTRACT,
    PATH_KEY,
    SECRETS_KEY,
    SERVERS_KEY,
    UTF8,
)


@dataclass(frozen=True)
class ServerSecretData:
    server_name: str
    secrets: Mapping

    def str_secrets(self) -> str:
        return yaml.safe_dump(self.secrets)


@dataclass(frozen=True)
class PaddedServerSecretData:
    server_name: str
    padded_secrets: str


@dataclass(frozen=True)
class EncryptedSecrets:
    server_name: str
    encrypted_key: str
    encrypted_secrets: str

    def export_secrets(self) -> Mapping[str, str]:
        server_name = "server_name"
        # Since we need to hardcode the name of the attribute here,
        # we throw an assertion error if ever the name of the attribute
        # would be changed without it being updated in this function.
        # There doesn't seem to be a way to use reflection
        assert hasattr(self, server_name)
        return {k: v for k, v in dataclasses.asdict(self).items() if k != server_name}


def args_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output_path",
        dest="output_path",
        required=True,
        type=str,
        help="path to the file in which we should write the "
        + "generated encrypted secrets",
    )
    parser.add_argument(
        "--ansible_vault_passwd",
        dest="ansible_vault_passwd",
        required=False,
        type=str,
        help="the ansible-vault password, if empty the script "
        + "will ask for the password",
    )
    parser.add_argument(
        "--secrets_directory",
        dest="secrets_directory",
        required=True,
        type=str,
        help="The directory containing the *-secrets.yml files, "
        + "encrypted with Ansible Vault",
    )
    parser.add_argument(
        "--tunnel_config_path", dest="tunnel_config_path", required=True
    )
    return parser


def get_secrets(secrets) -> Iterable[ServerSecretData]:
    def validate_secret(secret_name: str, secret: Any) -> Mapping:
        if not (
            isinstance(secret, Mapping)
            # The path should not be empty
            and secret.get(PATH_KEY)
            # Empty strings and lists are falsy in python, so we need to be more explicit here
            and isinstance(secret.get(CONTENT_KEY), str)
            and isinstance(secret.get(SERVERS_KEY), list)
        ):
            raise Exception(
                f"The secret {secret_name} should be a mapping containing "
                + f'the mandatory fields "{PATH_KEY}", "{CONTENT_KEY}" and "{SERVERS_KEY}".'
            )
        return secret

    # We filter the secret to only contain the whitelisted keys.
    def filter_secret(secret: Mapping) -> Mapping:
        whitelist = [PATH_KEY, CONTENT_KEY, DEFAULT_EXTRACT]
        return {k: v for k, v in secret.items() if k in whitelist}

    # Build a mapping from every server to its secrets
    def reducer(
        server_dict: Mapping[str, ServerSecretData], secret_item
    ) -> Mapping[str, ServerSecretData]:
        (secret_name, secret) = secret_item
        validate_secret(secret_name, secret)
        out = {**server_dict}
        for server in secret.get(SERVERS_KEY, []):
            existing_secrets = out[server].secrets if server in out else {}
            out[server] = ServerSecretData(
                server_name=server,
                secrets={**existing_secrets, secret_name: filter_secret(secret)},
            )
        return out

    init: Mapping[str, ServerSecretData] = {}
    return reduce(reducer, secrets.get(SECRETS_KEY, {}).items(), init).values()


def encrypt_data(data: PaddedServerSecretData, pubkey: PublicKey) -> EncryptedSecrets:
    # Encrypt the secrets with a new key generated on the fly.
    # Only short, random data should ever by encrypted with a public key.
    new_key = secret_lib.generate_symmetric_key()
    encrypted_secrets = secret_lib.encrypt_symmetric_string(
        new_key, data.padded_secrets
    )

    # Encrypt the newly generated key using the server's public key.
    encrypted_key = secret_lib.encrypt_asymmetric(pubkey, new_key)

    return EncryptedSecrets(
        server_name=data.server_name,
        encrypted_key=encrypted_key,
        encrypted_secrets=encrypted_secrets,
    )


# The only information still communicated by the ciphertext,
# is the length of the original plaintext.
# In order to hide the relative amount of secrets accessible by every server,
# we pad the plaintexts with newlines such that they all have equal length.
# It is important to look at the length in bytes, rather than
# the length in characters, to account for variable-width encoding.
def pad_secrets(data: List[ServerSecretData]) -> Iterable[PaddedServerSecretData]:
    # We round the max length up to the nearest 10**exp
    # So for instance, for exp = 3, 24869 -> 25000
    # Upper is the part > 10**exp, so for our example
    #   upper(24869) = 20000
    # For lower, we strip everything > 10**exp and then round it up to
    # the nearest multiple of 10**exp, so for our example
    #   lower(24869) = 5000
    def round_up(i: int, exp: int = 3) -> int:
        if i % 10**exp != 0:
            exp_high = exp + 1
            upper: int = i - i % 10**exp_high
            lower: int = ((i - upper) // 10**exp + 1) * 10**exp
            return upper + lower
        else:
            return i

    def reducer(length: int, data: ServerSecretData) -> int:
        return max(length, len(data.str_secrets().encode(UTF8)))

    padding_len = round_up(reduce(reducer, data, 0))

    def pad(secrets: str) -> str:
        return secrets.ljust(padding_len, "\n")

    return [
        PaddedServerSecretData(
            server_name=secret_data.server_name,
            padded_secrets=pad(secret_data.str_secrets()),
        )
        for secret_data in data
    ]


def write_secrets(
    encrypted_secrets_list: List[EncryptedSecrets], output_path: str
) -> bool:
    print(f"Writing generated secrets to {output_path}...")
    content = {
        encrypted_secrets.server_name: encrypted_secrets.export_secrets()
        for encrypted_secrets in encrypted_secrets_list
    }

    try:
        with open(output_path, "w") as f:
            yaml.safe_dump(content, f, default_style="|")
    except Exception:
        print("ERROR : failed to write generated secrets file")
        print(traceback.format_exc())
        return False
    print("Successfully wrote generated secrets")
    return True


def read_secrets_files(secrets_files: Iterable[str], ansible_passwd: str) -> Mapping:
    def reducer(secrets_data: Mapping, secrets_file: str) -> Mapping:
        print(f"Parsing {secrets_file}...")
        new_secrets = ansible_vault_lib.read_vault_file(ansible_passwd, secrets_file)

        # If we detect a duplicate secret, we run our more expensive method to list all duplicates
        if set(secrets_data.get(SECRETS_KEY, {}).keys()).intersection(
            set(new_secrets.get(SECRETS_KEY, {}).keys())
        ):
            check_duplicate_secrets(secrets_files, ansible_passwd)
            raise AssertionError("Duplicate secrets found, see above.")

        return ocb_nixos_lib.deep_merge(secrets_data, new_secrets)

    init: Mapping = {SECRETS_KEY: {}}
    return reduce(reducer, secrets_files, init)


def check_duplicate_secrets(secrets_files: Iterable[str], ansible_passwd: str) -> None:
    print("Finding duplicates...")

    def build_secrets_mapping(secrets_data: Mapping, secrets_file: str) -> Mapping:
        new_secrets = ansible_vault_lib.read_vault_file(ansible_passwd, secrets_file)

        # Make a mapping of every secret to the files defining a secret with that name
        secrets = {**secrets_data}
        for secret in new_secrets.get(SECRETS_KEY, {}).keys():
            files_found = secrets.get(secret, [])
            secrets[secret] = files_found + [secrets_file]

        return secrets

    secret: str
    files: Iterable[str]
    init: Mapping = {}
    for secret, files in reduce(build_secrets_mapping, secrets_files, init).items():
        if len(list(files)) > 1:
            print(
                f"ERROR: secret with name '{secret}' is defined in "
                + f"multiple files: {', '.join(files)}"
            )


def is_active_secret(tunnels_json: Mapping) -> Callable[[ServerSecretData], bool]:
    def wrapped(data: ServerSecretData) -> bool:
        return bool(
            tunnels_json["tunnels"]["per-host"]
            .get(data.server_name, {})
            .get("generate_secrets", True)
        )

    return wrapped


def main() -> None:
    args = args_parser().parse_args()

    # First, we fetch and load the secrets data
    secrets_files = glob.glob(
        os.path.join(args.secrets_directory, "**/*-secrets.yml"), recursive=True
    )

    secrets_dict = read_secrets_files(
        secrets_files, ansible_vault_lib.get_ansible_passwd(args.ansible_vault_passwd)
    )

    tunnels_json = ocb_nixos_lib.read_json_configs(args.tunnel_config_path)

    secrets = get_secrets(secrets_dict)
    # An iterator can only be consumed once,
    # so we transform it into a list before passing it along
    active_secrets = list(filter(is_active_secret(tunnels_json), secrets))
    padded_secrets = pad_secrets(active_secrets)

    write_secrets(
        [
            encrypt_data(secrets, pub_key)
            for secrets in padded_secrets
            for pub_key in [
                secret_lib.extract_public_key(
                    tunnels_json, secrets.server_name, args.tunnel_config_path
                )
            ]
            # pub_key is None when the public_key field is empty
            # this happens when we are provisioning servers
            if pub_key
        ],
        args.output_path,
    )


if __name__ == "__main__":
    main()
