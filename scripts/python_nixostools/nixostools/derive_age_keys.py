import json
import logging
import subprocess
from pathlib import Path

import ruamel.yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("nixostools/derive_age_keys")


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


def sync_sops_yaml(sops_yaml_file, age_keys):
    """
    Sync generated age keys with those listed in .sops.yaml
    It starts by adding keys to a list of yaml anchors in "keys", if it does not exist already, before
    adding all keys to the first age key group it finds in each creation_rules.
    More complex access rules for individual users/keys are not yet implemented.
    Also, only age keys are supported.
    """
    yaml = ruamel.yaml.YAML()
    with open(sops_yaml_file) as f:
        sops_yaml = yaml.load(f.read())

    for age_key_name, age_key in age_keys.items():
        if age_key in sops_yaml["keys"]:
            logger.info(f"already found key {age_key} in {sops_yaml_file}, skipping")
            continue
        logger.info(f"adding key {age_key} to {sops_yaml_file}")
        entry = ruamel.yaml.scalarstring.PlainScalarString(
            age_key, anchor=f"user_{age_key_name}"
        )
        sops_yaml["keys"].append(entry)

    for creation_rule in sops_yaml["creation_rules"]:
        group_index = [
            index
            for index, key_group in enumerate(creation_rule["key_groups"])
            if "age" in key_group
        ][0]
        group = creation_rule["key_groups"][group_index]
        # get host keys from the existing set, but replace all user keys
        # we need the exact same python object (identity) for anchors to work correctly.
        host_keys = [
            key for key in group["age"] if key.anchor.value.startswith("host_")
        ]
        user_keys = [
            key for key in sops_yaml["keys"] if key.anchor.value.startswith("user_")
        ]
        group["age"] = sorted(host_keys + user_keys, key=lambda k: k.anchor.value)

    with open(sops_yaml_file, "w") as f:
        yaml.dump(sops_yaml, f)


def main():
    age_keys = dict(derive_age_keys(Path("org-config/json/keys.json")))
    sync_sops_yaml(Path("org-config/.sops.yaml"), age_keys)


if __name__ == "__main__":
    main()
