import json
import subprocess
import sys
from pathlib import Path

import ruamel.yaml


def derive_age_keys(
    keys_json_file,
    age_key_dir,
):
    """Iterate over ssh public keys in keys.json and derive an age key where possible. (i.e. all non sk- ssh-pulic keys."""
    age_key_dir.mkdir(exist_ok=True)
    with open(keys_json_file) as f:
        keys_json = json.load(f)

    for username, data in keys_json.get("keys").items():
        for index, public_key in enumerate(data.get("public_keys")):
            suffix = "" if index == 0 else f"_{index}"
            age_file_name = f"{username}{suffix}"
            if isinstance(public_key, dict):
                if "publicKey" in public_key:
                    public_key = public_key.get("publicKey")
                else:
                    print(
                        f"WARNING: unsupported key for {age_file_name}: {public_key}, skipping",
                        file=sys.stderr,
                    )
                    continue

            if public_key.startswith("sk-"):
                print(
                    f"WARNING: unsupported key for {age_file_name}: {public_key}, skipping",
                    file=sys.stderr,
                )
                continue

            if (age_key_dir / age_file_name).exists():
                print(f"{age_file_name}: already exists, skipping", file=sys.stderr)
                continue

            subprocess.run(
                ["ssh-to-age", "-o", age_key_dir / age_file_name],
                input=public_key,
                check=True,
                text=True,
            )


def sync_sops_yaml(sops_yaml_file):
    """Sync generated age keys with those listed in .sops.yaml"""
    yaml = ruamel.yaml.YAML()
    with open(sops_yaml_file) as f:
        sops_data = yaml.load(f.read())

    print(sops_data)


def main():
    derive_age_keys(Path("org-config/json/keys.json"), Path("org-config/age_keys/"))
    sync_sops_yaml(Path("org-config/.sops.yaml"))


if __name__ == "__main__":
    main()
