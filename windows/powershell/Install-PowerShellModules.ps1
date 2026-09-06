#requires -Version 7.4
#requires -Modules Microsoft.PowerShell.PSResourceGet

<#
.SYNOPSIS
  Installs the latest stable versions of selected modules for the current user.

.DESCRIPTION
  Run in PowerShell 7.4 or later; administrator rights are not required.
  Uses PSResourceGet to resolve and install versions from PSGallery.
  Does not force reinstallation or modify profiles. Restart PowerShell
  after installation to load new versions.

.EXAMPLE
  pwsh -NoProfile -File .\Install-PowerShellModules.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateNotNullOrEmpty()]
  [string[]]$Name = @(
    'Terminal-Icons'
    'PSReadLine'
    'z'
  )
)

$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ShouldProcess(($Name -join ', '), 'Install latest stable modules from PSGallery for CurrentUser')) {
  Write-Host "Модули для установки: $($Name -join ', ')" -ForegroundColor Cyan
  Find-PSResource -Name $Name -Repository PSGallery -Type Module -ErrorAction Stop |
  Install-PSResource -Repository PSGallery -Scope CurrentUser -TrustRepository -PassThru -Confirm:$false -ErrorAction Stop

  Write-Host 'Module installation finished. Restart PowerShell to load new versions.'
}
