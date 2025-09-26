"""
Helpers to ease scripting sops (https://github.com/getsops/sops/) operations from python.

It makes a few opionated assumptions about sops & sops-nix usage:
- only age is used, no gpg or kms
- each age key has an unique name, possibly suffixed with "_2", etc
- host keys have a "host_" prefix in their name
- user keys have a "user_" prefix in their name
- a single age key group exists per creation rule

"""

import logging
from pathlib import Path

import ruamel.yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("nixostools.sops")


class SopsYaml:
    def __init__(self, sops_yaml_path: Path):
        self.path = sops_yaml_path
        self.yaml = ruamel.yaml.YAML()
        self.yaml.indent(mapping=2, sequence=4, offset=2)
        with open(sops_yaml_path) as f:
            self.raw = self.yaml.load(f.read())

    def list_keys(self, predicate=None):
        return {
            key.anchor.value: key
            for key in self.raw["keys"]
            if (predicate is None) or predicate(key.anchor.value)
        }

    def save(self):
        with open(self.path, "w") as f:
            self.yaml.dump(self.raw, f)

    @property
    def user_keys(self):
        return self.list_keys(lambda name: name.startswith("user_"))

    @property
    def host_keys(self):
        return self.list_keys(lambda name: name.startswith("host_"))

    def get_key(self, name):
        return self.list_keys().get(name)

    def set_key(self, name, key, replace=False):
        """Set a key by name. Optionally replace it if it exists,
        else raise an error if it does. Also check for host_ or user_ prefix. Does only check names, not duplicate keys."""
        if not (name.startswith("user_") or name.startswith("host_")):
            raise ValueError(
                f'The key name "{name}" starts neither with "host_" nor with "user_".'
            )

        existing_keys = list(self.list_keys().keys())
        old_entry_index = None
        if name in existing_keys:
            if not replace:
                raise ValueError(f'A key named "{name}" already exists.')
            else:
                old_entry_index = existing_keys.index(name)

        entry = ruamel.yaml.scalarstring.PlainScalarString(key, anchor=name)
        if old_entry_index:
            self.raw["keys"][old_entry_index] = entry
        else:
            self.raw["keys"].append(entry)

    def delete_key(self, name):
        index = list(self.list_keys().keys()).index(name)
        del self.raw["keys"][index]

    def list_creation_rules(self, predicate=None):
        rules = dict()
        for rule in self.raw["creation_rules"]:
            path_regex = rule["path_regex"]
            if predicate and not predicate(path_regex):
                continue
            groups = rule["key_groups"]
            assert len(groups) == 1, f"more than one key group found for {path_regex}"
            assert list(groups[0].keys()) == ["age"], (
                f"key group for {path_regex} does not use age"
            )
            keys = {key.anchor.value: key for key in groups[0]["age"]}
            rules[path_regex] = keys
        return rules

    def get_creation_rule(self, path_regex):
        matching = self.list_creation_rules(lambda p: p == path_regex)
        # sops matches rules in order, first one wins
        if matching:
            return list(matching.values())[0]

    def set_creation_rule(self, path_regex, key_names, replace=False):
        existing_rule = self.get_creation_rule(path_regex)
        known_keys = self.list_keys()
        if existing_rule and not replace:
            raise ValueError(f'A creation rule for "{path_regex}" already exists.')

        keys = []
        for key_name in key_names:
            assert key_name in known_keys, f'Key ${key_name} is not listed under "keys"'
            keys.append(
                # we need the exact same python object/identity as in .keys for anchors to work correctly.
                known_keys[key_name]
            )

        new_rule = {
            "path_regex": path_regex,
            "key_groups": [{"age": keys}],
        }

        if existing_rule:
            for index, rule in enumerate(self.raw["creation_rules"]):
                if rule["path_regex"] == path_regex:
                    self.raw["creation_rules"][index] = new_rule
                    return
        else:
            self.raw["creation_rules"].append(new_rule)

    def delete_creation_rule(self, path_regex):
        for index, rule in enumerate(self.raw["creation_rules"]):
            if rule["path_regex"] == path_regex:
                del self.raw["creation_rules"][index]
                return
        raise ValueError(f"No creation_rule matches {path_regex}")
