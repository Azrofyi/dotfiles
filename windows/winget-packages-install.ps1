<#
.SYNOPSIS
  Установка приложений через winget.

.DESCRIPTION
  Устанавливает основную группу приложений напрямую.
  Отдельную группу устанавливает через HTTP proxy.

  Перед установкой каждой группы запрашивает подтверждение.

.EXAMPLE
  .\winget-packages-install.ps1

.EXAMPLE
  .\winget-packages-install.ps1 -Proxy "http://127.0.0.1:10809"

.EXAMPLE
  .\winget-packages-install.ps1 -SkipProxyApps

.EXAMPLE
  .\winget-packages-install.ps1 -WhatIf

.EXAMPLE
  .\winget-packages-install.ps1 -Confirm:$false
#>

[CmdletBinding(
  SupportsShouldProcess,
  ConfirmImpact = 'High'
)]
param(
  [string]$Proxy,

  [switch]$SkipProxyApps,

  [ValidateNotNullOrEmpty()]
  [string]$Source = 'winget'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration

$PackageGroups = @(
  [pscustomobject]@{
    Title    = 'Основные приложения'
    UseProxy = $false
    Packages = @(
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
  }

  [pscustomobject]@{
    Title    = 'Приложения через proxy'
    UseProxy = $true
    Packages = @(
      'Discord.Discord'                   # Discord
      'DistroAV.DistroAV'                 # OBS plugin
    )
  }
)

# Коды WinGet, которые не считаем ошибками.
$WingetNoChangeExitCodes = @(
  -1978335189 # 0x8A15002B: no applicable update found
  -1978335135 # 0x8A150061: package already installed
)

#endregion Configuration

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

function Show-PackageGroup {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Title,

    [Parameter(Mandatory)]
    [string[]]$Packages
  )

  Write-Section -Title $Title

  Write-Host "Пакетов в группе: $($Packages.Count)" -ForegroundColor Gray

  foreach ($package in $Packages) {
    Write-Host "  - $package" -ForegroundColor DarkGray
  }

  Write-Host ''
}

function Resolve-Proxy {
  [CmdletBinding()]
  param(
    [string]$CurrentProxy
  )

  if (-not [string]::IsNullOrWhiteSpace($CurrentProxy)) {
    return $CurrentProxy.Trim()
  }

  $inputProxy = Read-Host (
    'Введите HTTP proxy, например http://127.0.0.1:10809'
  )

  if ([string]::IsNullOrWhiteSpace($inputProxy)) {
    return $null
  }

  return $inputProxy.Trim()
}

function Format-ExitCode {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [int]$ExitCode
  )

  $unsignedCode = if ($ExitCode -lt 0) {
    [long]$ExitCode + 4294967296
  }
  else {
    [long]$ExitCode
  }

  return '0x{0:X8}' -f $unsignedCode
}

function Enable-WingetProxyOption {
  [CmdletBinding()]
  param()

  & $WingetPath settings `
    --enable ProxyCommandLineOptions `
    --disable-interactivity |
  Out-Null

  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0) {
    $formattedCode = Format-ExitCode -ExitCode $exitCode

    throw (
      'Не удалось включить ProxyCommandLineOptions. ' +
      "Код: $formattedCode ($exitCode)"
    )
  }

  Write-Verbose 'WinGet ProxyCommandLineOptions enabled.'
}

function Install-WingetPackage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Id,

    [string]$Proxy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Source
  )

  $useProxy = -not [string]::IsNullOrWhiteSpace($Proxy)

  $wingetArgs = @(
    'install'
    '--id', $Id
    '--exact'
    '--source', $Source
    '--silent'
    '--disable-interactivity'
    '--accept-source-agreements'
    '--accept-package-agreements'
  )

  if ($useProxy) {
    $wingetArgs += @('--proxy', $Proxy)

    Write-Host (
      "[*] Установка через proxy: $Id"
    ) -ForegroundColor Cyan
  }
  else {
    Write-Host "[*] Установка: $Id" -ForegroundColor Cyan
  }

  # Не позволяем текстовому выводу winget попасть в результат функции.
  & $WingetPath @wingetArgs | Out-Host

  $exitCode = $LASTEXITCODE
  $formattedCode = Format-ExitCode -ExitCode $exitCode

  if ($exitCode -eq 0) {
    $status = 'Succeeded'

    Write-Host (
      "[OK] Установка завершена: $Id"
    ) -ForegroundColor Green
  }
  elseif ($exitCode -in $WingetNoChangeExitCodes) {
    $status = 'Current'

    Write-Host (
      "[SKIP] Уже установлено или обновление не требуется: $Id"
    ) -ForegroundColor DarkGreen
  }
  else {
    $status = 'Failed'

    Write-Warning (
      "[FAILED] $Id, code: $formattedCode ($exitCode)"
    )
  }

  return [pscustomobject]@{
    Id          = $Id
    Status      = $status
    ExitCode    = $exitCode
    ExitCodeHex = $formattedCode
    ViaProxy    = $useProxy
  }
}

function Show-InstallSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results
  )

  Write-Section -Title 'Итог'

  if ($Results.Count -eq 0) {
    Write-Host 'Установка не выполнялась.' -ForegroundColor Yellow
    return 0
  }

  $succeeded = @(
    $Results | Where-Object Status -eq 'Succeeded'
  )

  $current = @(
    $Results | Where-Object Status -eq 'Current'
  )

  $failed = @(
    $Results | Where-Object Status -eq 'Failed'
  )

  Write-Host (
    "Выполнено успешно: $($succeeded.Count)"
  ) -ForegroundColor Green

  foreach ($item in $succeeded) {
    $proxyLabel = if ($item.ViaProxy) { 'да' } else { 'нет' }

    Write-Host (
      "  + $($item.Id) proxy=$proxyLabel"
    ) -ForegroundColor DarkGreen
  }

  Write-Host (
    "Уже актуально: $($current.Count)"
  ) -ForegroundColor Green

  foreach ($item in $current) {
    $proxyLabel = if ($item.ViaProxy) { 'да' } else { 'нет' }

    Write-Host (
      "  = $($item.Id) proxy=$proxyLabel"
    ) -ForegroundColor DarkGreen
  }

  if ($failed.Count -eq 0) {
    Write-Host 'Сбоев нет.' -ForegroundColor Green
    return 0
  }

  Write-Host (
    "Неудачно: $($failed.Count)"
  ) -ForegroundColor Red

  foreach ($item in $failed) {
    $proxyLabel = if ($item.ViaProxy) { 'да' } else { 'нет' }

    Write-Host (
      "  - $($item.Id) " +
      "proxy=$proxyLabel " +
      "code=$($item.ExitCodeHex)"
    ) -ForegroundColor DarkRed
  }

  return 1
}

#endregion Helpers

#region Main

$wingetCommand = Get-Command winget.exe `
  -CommandType Application `
  -ErrorAction SilentlyContinue

if ($null -eq $wingetCommand) {
  throw '[X] winget.exe не найден.'
}

$WingetPath = $wingetCommand.Source
$allResults = @()

foreach ($group in $PackageGroups) {
  if ($group.UseProxy -and $SkipProxyApps.IsPresent) {
    Write-Section -Title $group.Title

    Write-Host (
      '[SKIP] Группа отключена параметром -SkipProxyApps.'
    ) -ForegroundColor Yellow

    continue
  }

  Show-PackageGroup `
    -Title $group.Title `
    -Packages $group.Packages

  $target = '{0} ({1} пакетов)' -f (
    $group.Title,
    $group.Packages.Count
  )

  if (-not $PSCmdlet.ShouldProcess($target, 'Установить группу')) {
    if (-not $WhatIfPreference) {
      Write-Host (
        "[SKIP] Группа «$($group.Title)» пропущена."
      ) -ForegroundColor Yellow
    }

    continue
  }

  $groupProxy = $null

  if ($group.UseProxy) {
    $groupProxy = Resolve-Proxy -CurrentProxy $Proxy

    if ([string]::IsNullOrWhiteSpace($groupProxy)) {
      Write-Warning (
        'Proxy не указан. Proxy-приложения пропущены.'
      )

      continue
    }

    Enable-WingetProxyOption
  }

  foreach ($package in $group.Packages) {
    $allResults += Install-WingetPackage `
      -Id $package `
      -Proxy $groupProxy `
      -Source $Source
  }
}

$scriptExitCode = Show-InstallSummary -Results $allResults
exit $scriptExitCode

#endregion Main
