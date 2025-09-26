import json
import logging
import subprocess
from pathlib import Path

from nixostools import sops_yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("nixostools/sync_users_to_sops_yaml")


def has_secret_access(users_json, key_name, path_regex):
    """
    Predicate to decide whether a given user should have access to a secret files matched
    by path_regex.
    Currently, all global admins as well as users with the devops_common role set to "admin"
    are considered admins on all hosts.
    """
    user_name = key_name.removeprefix("user_")
    is_global_admin = user_name in users_json["global_admins"]
    is_devops_common_admin = user_name in [
        user
        for user, role in users_json["users"]["roles"]["devops_common"][
            "enable"
        ].items()
        if role == "admin"
    ]
    return is_global_admin or is_devops_common_admin


def derive_age_keys(
    keys_json_file,
):
    """Iterate over ssh public keys in keys.json and derive an age key where possible. (i.e. all non sk- ssh-pulic keys."""
    with open(keys_json_file) as f:
        keys_json = json.load(f)

    for username, data in keys_json.get("keys").items():
        for index, public_key in enumerate(data.get("public_keys")):
            suffix = "" if index == 0 else f"_{index + 1}"
            age_key_name = f"user_{username}{suffix}"
            if isinstance(public_key, dict):
                logger.warning(
                    f"WARNING: unsupported key for {age_key_name}: {public_key}, skipping"
                )
                continue

            if public_key.startswith("sk-"):
                logger.warning(
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


def sync_sops_yaml(sops_yaml_file, users_json_file, age_keys):
    """
    Sync generated age keys with those listed in .sops.yaml
    It starts by adding keys to a list of yaml anchors in "keys", if it does not exist already, before
    adding all keys to the first age key group it finds in each creation_rules.
    More complex access rules for individual users/keys are not yet implemented.
    Also, only age keys are supported.
    """
    with open(users_json_file) as f:
        users_json = json.load(f)
    sops_config = sops_yaml.SopsYaml(sops_yaml_file)
    for age_key_name, age_key in age_keys.items():
        sops_config.set_key(age_key_name, age_key, replace=True)
    for path_regex, rule_keys in sops_config.list_creation_rules().items():
        # get host keys from the existing set, but update all user keys
        # we need the exact same python object (identity) for anchors to work correctly.
        host_keys = [
            name for name, key in rule_keys.items() if name.startswith("host_")
        ]
        user_keys = [
            name
            for name, key in sops_config.user_keys.items()
            if has_secret_access(users_json, name, path_regex)
        ]
        key_names = list(sorted(host_keys + user_keys))
        sops_config.set_creation_rule(path_regex, key_names, replace=True)
    sops_config.save()


def main():
    age_keys = dict(derive_age_keys(Path("org-config/json/keys.json")))
    sync_sops_yaml(
        Path("org-config/.sops.yaml"), Path("org-config/json/users.json"), age_keys
    )


if __name__ == "__main__":
    main()
