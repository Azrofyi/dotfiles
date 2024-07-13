Import-Module -Name Terminal-Icons

oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH/dracula.omp.json" | Invoke-Expression


Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows

################################################################################
#                         Environment Variables Aliases                        #
################################################################################

function Invoke-List-Path {
  $env:Path -split ';';
};
Set-Alias -Name "pathl" -Value "Invoke-List-Path";
