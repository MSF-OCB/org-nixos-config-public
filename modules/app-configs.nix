# The following YAML config ...
#
#   configs:
#     tests_configs:
#       path: test_configs
#       content: |
#         FOO=BARS
#       servers:
#         - demo-prod-host
#         - demo-uat-host
#
# ... would translate into:
{ config, ... }:
let
  cfg = rec {
    demo-prod-host = {
      # TODO, set options (for each config file):
      # - settings.systemd.tmpfiles
      # - settings.environment.etc
      #
      # ... content of the file could be wrote inline here or in
      # ./org-config/app_configs/
    };
    # e.g. to re-use a config file on different machines:
    demo-uat-host = demo-prod-host;
  };
  # ... or rather than centralizing everything there, we could do it directly in
  # ./org-config/hosts/ for each machine?
in
{
  settings = cfg.${config.settings.networking.hostname};
}
