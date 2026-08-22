#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
  Пост-инсталл настройка Windows.

.DESCRIPTION
  Выполняет базовую настройку Windows:
    - часовой пояс и NTP;
    - BIOS/RTC clock as UTC;
    - настройки мыши и клавиатуры;
    - подготовку WinGet;
    - включение WinGet ProxyCommandLineOptions;
    - установку/обновление базовых WinGet-компонентов;
    - опциональное включение Hyper-V.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -EnableHyperV

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -SkipHyperV

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -SkipWinget

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 `
    -TimeZoneId 'Russian Standard Time' `
    -MouseSpeed 6

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateNotNullOrEmpty()]
  [string]$TimeZoneId = 'Russian Standard Time',

  [ValidateNotNullOrEmpty()]
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

# В PowerShell 7+ самостоятельно обрабатываем exit codes native-команд.
# В Windows PowerShell 5.1 этой preference variable нет.
if (
  Get-Variable `
    -Name PSNativeCommandUseErrorActionPreference `
    -ErrorAction SilentlyContinue
) {
  $PSNativeCommandUseErrorActionPreference = $false
}

#region Constants

$script:WingetExitCodes = @{
  UpdateNotApplicable = -1978335189 # 0x8A15002B
  AlreadyInstalled    = -1978335135 # 0x8A150061
}

$script:WingetAcceptedExitCodes = @(
  0
  $script:WingetExitCodes.UpdateNotApplicable
  $script:WingetExitCodes.AlreadyInstalled
)

#endregion Constants

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

function Write-Notice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  Write-Host "[!] $Text" -ForegroundColor Yellow
}

#endregion Output

#region Helpers

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

function Invoke-NativeCommand {
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FilePath,

    [AllowEmptyCollection()]
    [string[]]$Arguments = @(),

    [int[]]$SuccessExitCodes = @(0),

    [switch]$Quiet
  )

  Write-Verbose (
    'Executing: {0} {1}' -f (
      $FilePath,
      ($Arguments -join ' ')
    )
  )

  if ($Quiet) {
    & $FilePath @Arguments | Out-Null
  }
  else {
    # Native stdout не должен попасть в output этой функции.
    & $FilePath @Arguments | Out-Host
  }

  $exitCode = $LASTEXITCODE

  if ($exitCode -notin $SuccessExitCodes) {
    $formattedCode = Format-ExitCode -ExitCode $exitCode

    throw (
      '{0} завершился с кодом {1} ({2}). Arguments: {3}' -f (
        $FilePath,
        $formattedCode,
        $exitCode,
        ($Arguments -join ' ')
      )
    )
  }

  return $exitCode
}

function Confirm-Choice {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Title,

    [Parameter(Mandatory)]
    [string]$Message,

    [bool]$Default = $false
  )

  $choices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&Да',
      'Выполнить операцию.'
    )

    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&Нет',
      'Пропустить операцию.'
    )
  )

  $defaultChoice = if ($Default) { 0 } else { 1 }

  $choice = $Host.UI.PromptForChoice(
    $Title,
    $Message,
    $choices,
    $defaultChoice
  )

  return $choice -eq 0
}

#endregion Helpers

#region Windows Settings

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

  Write-Ok 'Часовой пояс настроен'

  Write-Step 'Настройка Windows Time Service'

  Set-Service -Name w32time -StartupType Automatic
  Start-Service -Name w32time

  $configuredPeers = @(
    foreach ($peer in $NtpPeers) {
      $peer = $peer.Trim()

      if ([string]::IsNullOrWhiteSpace($peer)) {
        continue
      }

      # Если флаги уже указаны пользователем, оставляем как есть.
      if ($peer -match ',0x[0-9A-Fa-f]+$') {
        $peer
      }
      else {
        # 0x8 = NTP client mode.
        "$peer,0x8"
      }
    }
  )

  if ($configuredPeers.Count -eq 0) {
    throw 'Список NTP-серверов пуст.'
  }

  $peerList = $configuredPeers -join ' '
  $w32tmPath = Join-Path $env:SystemRoot 'System32\w32tm.exe'

  Invoke-NativeCommand `
    -FilePath $w32tmPath `
    -Arguments @(
    '/config'
    "/manualpeerlist:$peerList"
    '/syncfromflags:manual'
    '/update'
  ) `
    -Quiet |
  Out-Null

  Restart-Service -Name w32time

  Write-Ok "NTP настроен: $($configuredPeers -join ', ')"

  try {
    Invoke-NativeCommand `
      -FilePath $w32tmPath `
      -Arguments @('/resync') `
      -Quiet |
    Out-Null

    Write-Ok 'Время синхронизировано'
  }
  catch {
    # Конфигурация NTP уже применена.
    # Отсутствие сети или временная недоступность peer не должны
    # считать весь bootstrap неуспешным.
    Write-Notice (
      'NTP настроен, но немедленная синхронизация не удалась: ' +
      $_.Exception.Message
    )
  }
}

function Set-WindowsMouseSettings {
  [CmdletBinding()]
  param(
    [ValidateRange(1, 20)]
    [int]$Speed = 6
  )

  Write-Step "Настройка мыши: speed=$Speed"

  $path = 'HKCU:\Control Panel\Mouse'

  Set-ItemProperty `
    -Path $path `
    -Name 'MouseSensitivity' `
    -Value ([string]$Speed)

  Set-ItemProperty `
    -Path $path `
    -Name 'MouseSpeed' `
    -Value '0'

  Set-ItemProperty `
    -Path $path `
    -Name 'MouseThreshold1' `
    -Value '0'

  Set-ItemProperty `
    -Path $path `
    -Name 'MouseThreshold2' `
    -Value '0'

  Write-Ok 'Настройки мыши применены'
}

function Set-WindowsKeyboardSettings {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка клавиатуры'

  Set-ItemProperty `
    -Path 'HKCU:\Control Panel\Keyboard' `
    -Name 'KeyboardDelay' `
    -Value '0'

  Write-Ok 'Настройки клавиатуры применены'
}

function Set-WindowsBiosUtc {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка BIOS/RTC clock as UTC'

  $propertyParams = @{
    Path         = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
    Name         = 'RealTimeIsUniversal'
    Value        = 1
    PropertyType = 'DWord'
    Force        = $true
  }

  New-ItemProperty @propertyParams | Out-Null

  Write-Ok 'RealTimeIsUniversal=1 применён'
}

function Enable-WindowsHyperV {
  [CmdletBinding()]
  param()

  Write-Step 'Проверка Hyper-V'

  try {
    $feature = Get-WindowsOptionalFeature `
      -Online `
      -FeatureName 'Microsoft-Hyper-V' `
      -ErrorAction Stop

    if ($feature.State -eq 'Enabled') {
      Write-Ok 'Hyper-V уже включён'
      return
    }

    if ($feature.State -eq 'EnablePending') {
      Write-Notice (
        'Hyper-V уже ожидает завершения установки. ' +
        'Требуется перезагрузка.'
      )
      return
    }

    Write-Step 'Включение Hyper-V'

    $featureParams = @{
      Online      = $true
      FeatureName = 'Microsoft-Hyper-V'
      All         = $true
      NoRestart   = $true
      ErrorAction = 'Stop'
    }

    $result = Enable-WindowsOptionalFeature @featureParams

    if ($result.RestartNeeded) {
      Write-Notice (
        'Hyper-V включён. Для завершения установки требуется перезагрузка.'
      )
    }
    else {
      Write-Ok 'Hyper-V включён'
    }
  }
  catch {
    Write-Warning (
      'Не удалось включить Hyper-V: ' +
      $_.Exception.Message
    )
  }
}

#endregion Windows Settings

#region WinGet

function Invoke-WingetPackageAction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath,

    [Parameter(Mandatory)]
    [ValidateSet('install', 'upgrade')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Id,

    [ValidateNotNullOrEmpty()]
    [string]$Source = 'winget'
  )

  Write-Step "winget $Action $Id"

  $arguments = @(
    $Action
    '--id'
    $Id
    '--exact'
    '--source'
    $Source
    '--silent'
    '--disable-interactivity'
    '--accept-source-agreements'
    '--accept-package-agreements'
  )

  try {
    $exitCode = Invoke-NativeCommand `
      -FilePath $WingetPath `
      -Arguments $arguments `
      -SuccessExitCodes $script:WingetAcceptedExitCodes
  }
  catch {
    Write-Warning (
      "Не удалось выполнить winget $Action для ${Id}: " +
      $_.Exception.Message
    )

    return
  }

  if ($exitCode -eq 0) {
    Write-Ok "$Id обработан"
    return
  }

  if ($exitCode -eq $script:WingetExitCodes.UpdateNotApplicable) {
    Write-Skip "$Id уже актуален"
    return
  }

  if ($exitCode -eq $script:WingetExitCodes.AlreadyInstalled) {
    Write-Skip "$Id уже установлен"
    return
  }
}

function Enable-WingetProxyOption {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath
  )

  Write-Step 'Включение WinGet ProxyCommandLineOptions'

  Invoke-NativeCommand `
    -FilePath $WingetPath `
    -Arguments @(
    'settings'
    '--enable'
    'ProxyCommandLineOptions'
    '--disable-interactivity'
  ) `
    -Quiet |
  Out-Null

  Write-Ok 'WinGet ProxyCommandLineOptions включён'
}

function Invoke-WingetPreset {
  [CmdletBinding()]
  param()

  $wingetCommand = Get-Command `
    -Name 'winget.exe' `
    -CommandType Application `
    -ErrorAction SilentlyContinue

  if ($null -eq $wingetCommand) {
    throw (
      'winget.exe не найден. ' +
      'WinGet bootstrap не может быть выполнен.'
    )
  }

  $wingetPath = $wingetCommand.Source

  Write-Verbose "WinGet path: $wingetPath"

  # App Installer содержит сам WinGet client.
  Invoke-WingetPackageAction `
    -WingetPath $wingetPath `
    -Action upgrade `
    -Id 'Microsoft.AppInstaller'

  # Системная prerequisite-настройка для Install-WingetPackages.ps1.
  Enable-WingetProxyOption -WingetPath $wingetPath

  Invoke-WingetPackageAction `
    -WingetPath $wingetPath `
    -Action upgrade `
    -Id 'Microsoft.WindowsTerminal'

  Invoke-WingetPackageAction `
    -WingetPath $wingetPath `
    -Action install `
    -Id 'Microsoft.PowerShell'
}

#endregion WinGet

#region Main

if ($EnableHyperV -and $SkipHyperV) {
  throw (
    'Параметры -EnableHyperV и -SkipHyperV ' +
    'нельзя использовать одновременно.'
  )
}

if (
  $PSCmdlet.ShouldProcess(
    'Current user mouse settings',
    "Set mouse speed to $MouseSpeed and disable acceleration"
  )
) {
  Set-WindowsMouseSettings -Speed $MouseSpeed
}

if (
  $PSCmdlet.ShouldProcess(
    'Current user keyboard settings',
    'Set keyboard delay'
  )
) {
  Set-WindowsKeyboardSettings
}

if (
  $PSCmdlet.ShouldProcess(
    'Windows RTC configuration',
    'Configure hardware clock as UTC'
  )
) {
  Set-WindowsBiosUtc
}

if (
  $PSCmdlet.ShouldProcess(
    'Windows Time Service',
    "Configure timezone '$TimeZoneId' and NTP"
  )
) {
  Set-WindowsTimeSettings `
    -TimeZoneId $TimeZoneId `
    -NtpPeers $NtpPeers
}

if ($SkipWinget) {
  Write-Skip 'WinGet bootstrap пропущен'
}
elseif (
  $PSCmdlet.ShouldProcess(
    'WinGet',
    'Configure WinGet and baseline packages'
  )
) {
  Invoke-WingetPreset
}

$shouldEnableHyperV = $false

if ($EnableHyperV) {
  $shouldEnableHyperV = $true
}
elseif ($SkipHyperV) {
  Write-Skip 'Hyper-V пропущен'
}
elseif ($WhatIfPreference) {
  Write-Notice (
    'Hyper-V не выбран явно. В режиме -WhatIf интерактивный ' +
    'вопрос пропущен. Используйте -EnableHyperV -WhatIf для проверки.'
  )
}
else {
  $shouldEnableHyperV = Confirm-Choice `
    -Title 'Hyper-V' `
    -Message 'Включить Hyper-V?'
}

if (
  $shouldEnableHyperV -and
  $PSCmdlet.ShouldProcess(
    'Hyper-V',
    'Enable Windows optional feature'
  )
) {
  Enable-WindowsHyperV
}

if ($WhatIfPreference) {
  Write-Ok 'Проверка -WhatIf завершена'
}
else {
  Write-Ok 'Все операции завершены'
}

#endregion Main
