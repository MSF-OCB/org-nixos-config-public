# https://gist.github.com/vmandic/ef80f1097521c16063b3b1c3a687d244
# Script for batch installing Visual Studio Code extensions
# Specify extensions to be checked & installed by modifying $extensions
#
$extensions =
    "EditorConfig.EditorConfig",
    "formulahendry.auto-close-tag",
    "formulahendry.auto-rename-tag",
    "ms-vscode-remote.remote-ssh",
    "ms-vscode-remote.remote-ssh-edit",
    "ms-vscode-remote.remote-wsl@0.76.0",
    "bbenoist.nix",
    "mkhl.direnv",
    "jnoortheen.nix-ide",
    "esbenp.prettier-vscode",
    "timonwong.shellcheck",
    "ms-vscode-remote.vscode-remote-extensionpack"

foreach ($ext in $extensions) {
    Write-Host "Installing" $ext "..." -ForegroundColor White
    . 'code.cmd' --install-extension $ext
}
