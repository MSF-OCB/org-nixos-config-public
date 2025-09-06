import argparse
import os

import yaml

from nixostools import util_lib


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
        "--configs_path",
        type=str,
        required=True,
        dest="configs_path",
        help="path to the file containing the generated configs",
    )
    parser.add_argument(
        "--output_path",
        type=str,
        required=True,
        dest="output_path",
        help="path to the folder where we should output the app configs to",
    )
    return parser


def validate_paths(configs_path, output_path):
    not_a_file_msg = "the given path is not a file or does not exist."
    if not os.path.isfile(configs_path):
        raise Exception(
            f"Cannot open the app configs file ({configs_path}), " + not_a_file_msg
        )
    if not os.path.isdir(output_path):
        raise Exception(
            f"The output path for app configs is not a directory ({output_path})"
        )


def main():
    args = args_parser().parse_args()
    validate_paths(args.configs_path, args.output_path)
    with open(args.configs_path) as f:
        all_configs = yaml.safe_load(f)

    configs_data = all_configs.get(args.server_name)
    if configs_data:
        util_lib.write_files(args.output_path, configs_data)


if __name__ == "__main__":
    main()
