import argparse
import os

import yaml

from nixostools import secret_lib, util_lib


def args_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--server_name",
        type=str,
        required=True,
        dest="server_name",
        help="name of the server we are running this script on",
    )
    parser.add_argument(
        "--secrets_path",
        type=str,
        required=True,
        dest="secrets_path",
        help="path to the file containing the generated secrets",
    )
    parser.add_argument(
        "--output_path",
        type=str,
        required=True,
        dest="output_path",
        help="path to the folder where we should output the secrets to",
    )
    parser.add_argument(
        "--private_key_file",
        type=str,
        required=True,
        dest="private_key_file",
        help="private key file of the server",
    )
    parser.add_argument(
        "--extract_all",
        action="store_true",
        dest="extract_all",
        help="extract-all secrets including these default_extract: false",
    )
    return parser


def validate_file(file):
    not_a_file_msg = "the given path is not a file or does not exist."
    if not os.path.isfile(file):
        raise Exception(f"Cannot open the file ({file}), " + not_a_file_msg)


def validate_dir(dir):
    not_a_dir_msg = "the given path is not a directory or does not exist."
    if not os.path.isdir(dir):
        raise Exception(f"Cannot open the file ({dir}), " + not_a_dir_msg)


def main():
    args = args_parser().parse_args()
    validate_file(args.secrets_path)
    validate_dir(args.output_path)

    with open(args.secrets_path) as f:
        all_secrets = yaml.safe_load(f)

    secrets_data = all_secrets.get(args.server_name)
    if secrets_data:
        validate_file(args.private_key_file)
        with open(args.private_key_file) as f:
            server_privk = f.read()
        # decrypt the symmetric key using the server private key
        key = secret_lib.decrypt_asymmetric(
            secret_lib.extract_curve_private_key(server_privk),
            secrets_data["encrypted_key"],
        )
        # then use it to decrypt the secrets
        decrypted_secrets = yaml.safe_load(
            secret_lib.decrypt_symmetric(key, secrets_data["encrypted_secrets"])
        )
        util_lib.write_files(args.output_path, decrypted_secrets, args.extract_all)


if __name__ == "__main__":
    main()
