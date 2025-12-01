# Install Choco
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

choco install -y vale
choco install -y --ignore-checksums googlechrome
$chromeLocation = 'C:\Program Files\Google\Chrome\Application'
choco install -y neovim
choco install -y vscode
choco install -y curl
choco install -y git

# set default applications.
choco install -y SetDefaultBrowser
SetDefaultBrowser HKLM "Google Chrome"

Write-Output '* Configuring environment'
refreshenv
$env:PATH=$env:PATH + ';C:\Program Files\Git\bin' + ';C:\Program Files\Microsoft VS Code\bin'
[Environment]::SetEnvironmentVariable('PATH', $env:PATH, [EnvironmentVariableTarget]::Machine)
