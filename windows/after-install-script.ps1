#requires -RunAsAdministrator
<#
.SYNOPSIS
  Пост-инсталл настройка Windows.

.DESCRIPTION
  Настраивает время, BIOS UTC, мышь, клавиатуру, базовые winget-компоненты
  и опционально включает Hyper-V.

.EXAMPLE
  .\after-install-script.ps1

.EXAMPLE
  .\after-install-script.ps1 -EnableHyperV

.EXAMPLE
  .\after-install-script.ps1 -SkipHyperV

.EXAMPLE
  .\after-install-script.ps1 -TimeZoneId "Russian Standard Time" -MouseSpeed 6
#>

[CmdletBinding()]
param(
  [string]$TimeZoneId = 'Russian Standard Time',

  [string[]]$NtpPeers = @(
    '0.pool.ntp.org'
    '1.pool.ntp.org'
    '2.pool.ntp.org'
    '3.pool.ntp.org'
  ),

  [ValidateRange(1, 20)]
  [int]$MouseSpeed = 6,

  [switch]$EnableHyperV,

  [switch]$SkipHyperV,

  [switch]$SkipWinget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Output

function Write-Step {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  Write-Host "[*] $Text" -ForegroundColor Cyan
}

function Write-Ok {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Skip {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  Write-Host "[SKIP] $Text" -ForegroundColor Yellow
}

#endregion Output

#region Helpers

function Invoke-Confirmed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Message,

    [Parameter(Mandatory)]
    [scriptblock]$Action
  )

  $choice = Read-Host "$Message (y/n)"

  if ($choice -match '^(y|Y)$') {
    & $Action
    return
  }

  Write-Skip $Message
}

function Invoke-NativeCommand {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [Parameter(Mandatory)]
    [string[]]$Arguments,

    [switch]$IgnoreExitCode
  )

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
    throw "$FilePath завершился с кодом $exitCode. Arguments: $($Arguments -join ' ')"
  }

  return $exitCode
}

function Test-CommandExists {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

#endregion Helpers

#region Settings

function Set-WindowsTimeSettings {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$TimeZoneId,

    [Parameter(Mandatory)]
    [string[]]$NtpPeers
  )

  Write-Step "Настройка часового пояса: $TimeZoneId"
  Set-TimeZone -Id $TimeZoneId
  Write-Ok "Часовой пояс настроен"

  Write-Step 'Настройка Windows Time Service'

  Set-Service w32time -StartupType Automatic
  Start-Service w32time -ErrorAction SilentlyContinue

  $peerList = $NtpPeers -join ' '

  Invoke-NativeCommand -FilePath 'w32tm.exe' -Arguments @(
    '/config'
    "/manualpeerlist:$peerList"
    '/syncfromflags:manual'
    '/update'
  ) -IgnoreExitCode | Out-Null

  Restart-Service w32time

  Invoke-NativeCommand -FilePath 'w32tm.exe' -Arguments @('/resync') -IgnoreExitCode | Out-Null

  Write-Ok 'Синхронизация времени настроена'
}

function Set-WindowsMouseSettings {
  [CmdletBinding()]
  param(
    [ValidateRange(1, 20)]
    [int]$Speed = 6
  )

  Write-Step "Настройка мыши: speed=$Speed"

  $path = 'HKCU:\Control Panel\Mouse'

  Set-ItemProperty -Path $path -Name 'MouseSensitivity' -Value $Speed
  Set-ItemProperty -Path $path -Name 'MouseSpeed' -Value 0
  Set-ItemProperty -Path $path -Name 'MouseThreshold1' -Value 0
  Set-ItemProperty -Path $path -Name 'MouseThreshold2' -Value 0

  Write-Ok 'Настройки мыши применены'
}

function Set-WindowsKeyboardSettings {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка клавиатуры'

  $path = 'HKCU:\Control Panel\Keyboard'

  Set-ItemProperty -Path $path -Name 'KeyboardDelay' -Value 0

  Write-Ok 'Настройки клавиатуры применены'
}

function Set-WindowsBiosUtc {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка BIOS clock as UTC'

  $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'

  New-ItemProperty `
    -Path $path `
    -Name 'RealTimeIsUniversal' `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

  Write-Ok 'RealTimeIsUniversal=1 применён'
}

function Enable-WindowsHyperV {
  [CmdletBinding()]
  param()

  Write-Step 'Включение Hyper-V'

  try {
    $result = Enable-WindowsOptionalFeature `
      -Online `
      -FeatureName Microsoft-Hyper-V `
      -All `
      -NoRestart `
      -ErrorAction Stop

    if ($result.RestartNeeded) {
      Write-Skip 'Для завершения установки Hyper-V требуется перезагрузка'
    }
    else {
      Write-Ok 'Hyper-V включён'
    }
  }
  catch {
    Write-Warning "Не удалось включить Hyper-V: $($_.Exception.Message)"
  }
}

#endregion Settings

#region Winget

function Invoke-WingetPackageAction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('install', 'upgrade')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$Id
  )

  if (-not (Test-CommandExists -Name 'winget')) {
    Write-Skip 'winget не найден'
    return
  }

  Write-Step "winget $Action $Id"

  $arguments = @(
    $Action
    '--id', $Id
    '--exact'
    '--accept-source-agreements'
    '--accept-package-agreements'
    '--disable-interactivity'
    '--source', 'winget'
  )

  $exitCode = Invoke-NativeCommand `
    -FilePath 'winget.exe' `
    -Arguments $arguments `
    -IgnoreExitCode

  if ($exitCode -eq 0) {
    Write-Ok "$Id обработан"
  }
  else {
    Write-Skip "$Id завершился с кодом $exitCode"
  }
}

function Enable-WingetProxyOption {
  [CmdletBinding()]
  param()

  if (-not (Test-CommandExists -Name 'winget')) {
    Write-Skip 'winget не найден'
    return
  }

  try {
    Invoke-NativeCommand `
      -FilePath 'winget.exe' `
      -Arguments @('settings', '--enable', 'ProxyCommandLineOptions') `
      -IgnoreExitCode | Out-Null

    Write-Ok 'Включена опция winget: ProxyCommandLineOptions'
  }
  catch {
    Write-Skip "Не удалось применить winget settings: $($_.Exception.Message)"
  }
}

function Invoke-WingetPreset {
  [CmdletBinding()]
  param()

  if (-not (Test-CommandExists -Name 'winget')) {
    Write-Skip 'winget не найден — winget preset пропущен'
    return
  }

  Invoke-WingetPackageAction -Action upgrade -Id 'Microsoft.WindowsTerminal'
  Invoke-WingetPackageAction -Action upgrade -Id 'Microsoft.AppInstaller'
  Invoke-WingetPackageAction -Action install -Id 'Microsoft.PowerShell'

  Enable-WingetProxyOption
}

#endregion Winget

#region Main

Set-WindowsMouseSettings -Speed $MouseSpeed
Set-WindowsKeyboardSettings
Set-WindowsBiosUtc
Set-WindowsTimeSettings -TimeZoneId $TimeZoneId -NtpPeers $NtpPeers

if (-not $SkipWinget) {
  Invoke-WingetPreset
}
else {
  Write-Skip 'winget preset пропущен'
}

if ($EnableHyperV) {
  Enable-WindowsHyperV
}
elseif (-not $SkipHyperV) {
  Invoke-Confirmed -Message 'Включить Hyper-V?' -Action {
    Enable-WindowsHyperV
  }
}
else {
  Write-Skip 'Hyper-V пропущен'
}

Write-Ok 'Все операции завершены'

#endregion Main
