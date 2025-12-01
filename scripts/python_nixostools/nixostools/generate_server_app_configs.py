import argparse
import glob
import os
import traceback
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from functools import reduce
from typing import Any, Callable

import yaml

from nixostools import ocb_nixos_lib
from nixostools.config_lib import CONFIGS_KEY, CONTENT_KEY, PATH_KEY, SERVERS_KEY


@dataclass(frozen=True)
class ServerConfigData:
    server_name: str
    configs: Mapping

    def str_configs(self) -> Mapping:
        return self.configs


def args_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output_path",
        dest="output_path",
        required=True,
        type=str,
        help="path to the file in which we should write the " + "generated configs",
    )
    parser.add_argument(
        "--configs_directory",
        dest="configs_directory",
        required=True,
        type=str,
        help="The directory containing the *-configs.yml files",
    )
    parser.add_argument(
        "--tunnel_config_path", dest="tunnel_config_path", required=True
    )
    return parser


def get_configs(configs) -> Iterable[ServerConfigData]:
    def validate_config(config_name: str, config: Any) -> Mapping:
        if not (
            isinstance(config, Mapping)
            and config.get(PATH_KEY)
            and config.get(CONTENT_KEY)
            and config.get(SERVERS_KEY)
        ):
            raise Exception(
                f"The config {config_name} should be a mapping containing "
                + f'the mandatory fields "{PATH_KEY}", "{CONTENT_KEY}" and "{SERVERS_KEY}".'
            )
        return config

    # We filter the config to only contain the whitelisted keys.
    def filter_config(config: Mapping) -> Mapping:
        whitelist = [PATH_KEY, CONTENT_KEY]
        return {k: v for k, v in config.items() if k in whitelist}

    # Build a mapping from every server to its configs
    def reducer(
        server_dict: Mapping[str, ServerConfigData], config_item
    ) -> Mapping[str, ServerConfigData]:
        (config_name, config) = config_item
        validate_config(config_name, config)
        out = {**server_dict}
        for server in config.get(SERVERS_KEY, []):
            existing_configs = out[server].configs if server in out else {}
            out[server] = ServerConfigData(
                server_name=server,
                configs={**existing_configs, config_name: filter_config(config)},
            )
        return out

    init: Mapping[str, ServerConfigData] = {}
    return reduce(reducer, configs.get(CONFIGS_KEY, {}).items(), init).values()


def str_presenter(dumper, data):
    if len(data.splitlines()) > 1:  # check for multiline string
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


def write_configs(configs_list: list[ServerConfigData], output_path: str) -> bool:
    print(f"Writing generated app configs to {output_path}...")
    content = {configs.server_name: configs.str_configs() for configs in configs_list}
    yaml.representer.SafeRepresenter.add_representer(str, str_presenter)
    try:
        with open(output_path, "w") as f:
            yaml.safe_dump(content, f)
    except Exception:
        print("ERROR : failed to write generated app configs file")
        print(traceback.format_exc())
        return False
    print("Successfully wrote generated app configs")
    return True


def read_config_file(config_file_name: str) -> Mapping:
    if os.path.isfile(config_file_name):
        with open(config_file_name) as f:
            return yaml.safe_load(f)
    else:
        raise FileNotFoundError(f"App Config file: ({config_file_name}): no such file!")


def read_configs_files(configs_files: Iterable[str]) -> Mapping:
    def reducer(configs_data: Mapping, configs_file: str) -> Mapping:
        print(f"Parsing {configs_file}...")
        new_configs = read_config_file(configs_file)
        # If we detect a duplicate config, we run our more expensive method to list all duplicates
        if set(configs_data.get(CONFIGS_KEY, {}).keys()).intersection(
            set(new_configs.get(CONFIGS_KEY, {}).keys())
        ):
            check_duplicate_configs(new_configs)
            raise AssertionError("Duplicate app configs found, see above.")

        return ocb_nixos_lib.deep_merge(configs_data, new_configs)

    init: Mapping = {CONFIGS_KEY: {}}
    return reduce(reducer, configs_files, init)


def check_duplicate_configs(configs_files: Iterable[str]) -> None:
    print("Finding duplicates...")

    def build_configs_mapping(configs_data: Mapping, configs_file: str) -> Mapping:
        new_configs = read_config_file(configs_file)

        # Make a mapping of every config to the files defining a config with that name
        configs = {**configs_data}
        for config in new_configs.get(CONFIGS_KEY, {}).keys():
            files_found = configs.get(config, [])
            configs[config] = files_found + [configs_file]

        return configs

    config: str
    files: Iterable[str]
    init: Mapping = {}
    for config, files in reduce(build_configs_mapping, configs_files, init).items():
        if len(list(files)) > 1:
            print(
                f"ERROR: app config with name '{config}' is defined in "
                + f"multiple files: {', '.join(files)}"
            )


def is_active_config(tunnels_json: Mapping) -> Callable[[ServerConfigData], bool]:
    def wrapped(data: ServerConfigData) -> bool:
        return bool(
            tunnels_json["tunnels"]["per-host"]
            .get(data.server_name, {})
            .get("generate_configs", True)
        )

    return wrapped


def main() -> None:
    args = args_parser().parse_args()

    ### First, we fetch and load the configs data
    configs_files = glob.glob(
        os.path.join(args.configs_directory, "**/*-configs.yml"), recursive=True
    )
    configs_dict = read_configs_files(configs_files)
    tunnels_json = ocb_nixos_lib.read_json_configs(args.tunnel_config_path)
    configs = get_configs(configs_dict)
    active_configs = list(filter(is_active_config(tunnels_json), configs))
    write_configs(active_configs, args.output_path)


if __name__ == "__main__":
    main()
