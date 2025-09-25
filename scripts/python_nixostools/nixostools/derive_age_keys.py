import json
import logging
import subprocess
import sys
from pathlib import Path

import ruamel.yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def derive_age_keys(
    keys_json_file,
):
    """Iterate over ssh public keys in keys.json and derive an age key where possible. (i.e. all non sk- ssh-pulic keys."""
    with open(keys_json_file) as f:
        keys_json = json.load(f)

    for username, data in keys_json.get("keys").items():
        for index, public_key in enumerate(data.get("public_keys")):
            suffix = "" if index == 0 else f"_{index + 1}"
            age_key_name = f"{username}{suffix}"
            if isinstance(public_key, dict):
                if "publicKey" in public_key:
                    public_key = public_key.get("publicKey")
                else:
                    logger.warn(
                        f"WARNING: unsupported key for {age_key_name}: {public_key}, skipping"
                    )
                    continue

            if public_key.startswith("sk-"):
                logger.warn(
                    f"WARNING: unsupported key for {age_key_name}: {public_key}, skipping"
                )
                continue

            age_key = subprocess.run(
                ["ssh-to-age"],
                input=public_key,
                capture_output=True,
                check=True,
                text=True,
            ).stdout.strip()
            yield (age_key_name, age_key)


def sync_sops_yaml(sops_yaml_file):
    """Sync generated age keys with those listed in .sops.yaml"""
    yaml = ruamel.yaml.YAML()
    with open(sops_yaml_file) as f:
        sops_data = yaml.load(f.read())

    print(sops_data)


def main():
    sync_sops_yaml(Path("org-config/.sops.yaml"))
    age_keys = dict(derive_age_keys(Path("org-config/json/keys.json")))


if __name__ == "__main__":
    main()
