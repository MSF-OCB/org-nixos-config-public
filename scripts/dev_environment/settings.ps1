$lang = "fr-FR"
Write-Output "Adding secondary keyboard $lang..."
$old_langs = Get-WinUserLanguageList
$old_langs.Add("$lang")
Set-WinUserLanguageList -LanguageList $old_langs -Force

Set-Culture fr-FR
Set-TimeZone -Id "W. Europe Standard Time"

## Disable Windows Defender.
Write-Host "Disabling Windows Defender..."
Set-MpPreference -DisableRealtimeMonitoring $true

Set-WindowsExplorerOptions -EnableShowHiddenFilesFoldersDrives -EnableShowProtectedOSFiles -EnableShowFileExtensions -EnableShowFullPathInTitleBar
