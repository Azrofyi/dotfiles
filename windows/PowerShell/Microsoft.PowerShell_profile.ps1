Import-Module -Name Terminal-Icons

oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH/dracula.omp.json" | Invoke-Expression

Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -HistoryNoDuplicates:$True
Set-PSReadLineOption -ShowToolTips:$True
Set-PSReadLineKeyHandler -Chord 'Enter' -Function ValidateAndAcceptLine

Function Invoke-List-Path {
  $env:Path -split ';'
};

Function Which ($command) {
  Get-Command -Name $command -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue
}

Function UpdateAll {
  winget.exe upgrade --recurse --source winget --verbose
}

Set-Alias -Name "pathl" -Value "Invoke-List-Path"
Set-Alias -Name "ll" -Value "Get-ChildItem"
Set-Alias -Name "touch" -Value "New-Item"
