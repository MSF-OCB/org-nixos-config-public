import os
import traceback
from collections.abc import Mapping


def is_default_extract(configuration: Mapping) -> bool:
    if (
        configuration.get("default_extract")
        and configuration["default_extract"].lower() == "false"
    ):
        return False
    else:
        return True


def do_write_file(output_path: str, config_file: Mapping):
    with open(output_path, "w") as f:
        f.write(config_file["content"])
        print(f"wrote {output_path}")


def write_files(
    output_path_prefix: str, configurations: Mapping, extract_all: bool = False
):
    for configuration in configurations.values():
        if not extract_all and not is_default_extract(configuration):
            continue
        output_path = os.path.join(output_path_prefix, configuration["path"])
        try:
            do_write_file(output_path, configuration)
        except Exception:
            print(f"ERROR : failed to write to {configuration['path']}")
            print(traceback.format_exc())
