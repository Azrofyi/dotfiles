<#
.SYNOPSIS
  Установка приложений через winget.

.DESCRIPTION
  Ставит основной список приложений напрямую.
  Отдельный список приложений ставит через HTTP proxy.

.EXAMPLE
  .\winget-packages-install.ps1

.EXAMPLE
  .\winget-packages-install.ps1 -Proxy "http://127.0.0.1:10809"

.EXAMPLE
  .\winget-packages-install.ps1 -SkipProxyApps
#>

[CmdletBinding()]
param(
  [string]$Proxy,

  [switch]$SkipProxyApps,

  [string]$Source = 'winget'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Package lists

$Apps = @(
  'JanDeDobbeleer.OhMyPosh'           # OhMyPosh
  'M2Team.NanaZip'                    # NanaZip
  'FxSound.FxSound'                   # FxSound
  'LibreWolf.LibreWolf'               # LibreWolf
  'Brave.Brave'                       # Brave
  'qBittorrent.qBittorrent'           # qBittorrent
  'Telegram.TelegramDesktop'          # Telegram
  '2dust.v2rayN'                      # v2rayN
  'Spotify.Spotify'                   # Spotify
  'Obsidian.Obsidian'                 # Obsidian
  'OBSProject.OBSStudio'              # OBS Studio
  'VideoLAN.VLC'                      # VLC
  'Microsoft.VisualStudioCode'        # VS Code
  'Neovim.Neovim'                     # Neovim
  'cURL.cURL'                         # curl
  'Git.Git'                           # Git
  'Docker.DockerDesktop'              # Docker Desktop
  'Gyan.FFmpeg'                       # FFmpeg
  'Audacity.Audacity'                 # Audacity
  'LocalSend.LocalSend'               # LocalSend
)

$ProxyApps = @(
  'Discord.Discord'                   # Discord
  'DistroAV.DistroAV'                 # OBS plugin
)

#endregion Package lists

#region Helpers

function Write-Section {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Title
  )

  Write-Host ''
  Write-Host "========== $Title ==========" -ForegroundColor White
}

function Test-Winget {
  [CmdletBinding()]
  param()

  return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Enable-WingetProxyOption {
  [CmdletBinding()]
  param()

  try {
    winget settings --enable ProxyCommandLineOptions | Out-Null
    Write-Verbose 'Winget ProxyCommandLineOptions enabled.'
  }
  catch {
    Write-Warning "Не удалось включить ProxyCommandLineOptions: $($_.Exception.Message)"
  }
}

function Read-Proxy {
  [CmdletBinding()]
  param(
    [string]$CurrentProxy
  )

  if (-not [string]::IsNullOrWhiteSpace($CurrentProxy)) {
    return $CurrentProxy
  }

  $inputProxy = Read-Host 'Введите HTTP proxy, например http://127.0.0.1:10809'

  if ([string]::IsNullOrWhiteSpace($inputProxy)) {
    return $null
  }

  return $inputProxy
}

function Install-WingetPackage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Id,

    [string]$Proxy,

    [Parameter(Mandatory)]
    [string]$Source
  )

  $wingetArgs = @(
    'install'
    '--id', $Id
    '--exact'
    '--accept-source-agreements'
    '--accept-package-agreements'
    '--disable-interactivity'
    '--source', $Source
  )

  if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    $wingetArgs += @('--proxy', $Proxy)
    Write-Host "[*] Установка через proxy: $Id" -ForegroundColor Cyan
  }
  else {
    Write-Host "[*] Установка: $Id" -ForegroundColor Cyan
  }

  winget @wingetArgs
  $exitCode = $LASTEXITCODE

  if ($exitCode -eq 0) {
    Write-Host "[OK] Установлено/актуально: $Id" -ForegroundColor Green

    return [pscustomobject]@{
      Id       = $Id
      Status   = 'Installed'
      ExitCode = $exitCode
      Proxy    = if ([string]::IsNullOrWhiteSpace($Proxy)) { 'No' } else { 'Yes' }
    }
  }

  Write-Warning "[FAILED] $Id, code: $exitCode"

  return [pscustomobject]@{
    Id       = $Id
    Status   = 'Failed'
    ExitCode = $exitCode
    Proxy    = if ([string]::IsNullOrWhiteSpace($Proxy)) { 'No' } else { 'Yes' }
  }
}

function Install-WingetPackages {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string[]]$Packages,

    [string]$Proxy,

    [Parameter(Mandatory)]
    [string]$Source
  )

  if ($Packages.Count -eq 0) {
    return @()
  }

  $results = foreach ($package in $Packages) {
    Install-WingetPackage -Id $package -Proxy $Proxy -Source $Source
  }

  return @($results)
}

function Show-InstallSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Results
  )

  $installed = @($Results | Where-Object { $_.Status -eq 'Installed' })
  $failed = @($Results | Where-Object { $_.Status -eq 'Failed' })

  Write-Section -Title 'Итог'

  Write-Host ("Успешно: {0}" -f $installed.Count) -ForegroundColor Green
  foreach ($item in $installed) {
    Write-Host ("  + {0} proxy={1}" -f $item.Id, $item.Proxy) -ForegroundColor DarkGreen
  }

  if ($failed.Count -gt 0) {
    Write-Host ("Неудачно: {0}" -f $failed.Count) -ForegroundColor Red

    foreach ($item in $failed) {
      Write-Host ("  - {0} proxy={1} code={2}" -f $item.Id, $item.Proxy, $item.ExitCode) -ForegroundColor DarkRed
    }

    exit 1
  }

  Write-Host 'Сбоев нет.' -ForegroundColor Green
}

#endregion Helpers

#region Main

if (-not (Test-Winget)) {
  Write-Error '[X] winget не найден.'
  exit 1
}

$allResults = @()

Write-Section -Title 'Основные приложения'
$allResults += Install-WingetPackages -Packages $Apps -Source $Source

if (-not $SkipProxyApps) {
  Write-Section -Title 'Приложения через proxy'

  $resolvedProxy = Read-Proxy -CurrentProxy $Proxy

  if ([string]::IsNullOrWhiteSpace($resolvedProxy)) {
    Write-Warning 'Proxy не указан. Proxy-приложения пропущены.'
  }
  else {
    Enable-WingetProxyOption
    $allResults += Install-WingetPackages -Packages $ProxyApps -Proxy $resolvedProxy -Source $Source
  }
}

Show-InstallSummary -Results $allResults

#endregion Main
