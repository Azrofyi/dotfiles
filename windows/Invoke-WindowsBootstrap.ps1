#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
  Пост-инсталл настройка Windows.

.DESCRIPTION
  Выполняет базовую настройку Windows:
    - часовой пояс и NTP;
    - интерпретацию BIOS/RTC clock как UTC;
    - настройки мыши и клавиатуры текущего пользователя;
    - подготовку WinGet;
    - включение WinGet ProxyCommandLineOptions;
    - установку/обновление базовых WinGet-компонентов;
    - опциональное включение Hyper-V.

.PARAMETER TimeZoneId
  Идентификатор часового пояса Windows.

.PARAMETER NtpPeers
  Список NTP-серверов. Если у peer не указаны флаги w32time,
  автоматически добавляется 0x8 (NTP client mode).

.PARAMETER MouseSpeed
  Скорость указателя мыши от 1 до 20.

.PARAMETER EnableHyperV
  Включить Hyper-V без интерактивного запроса.

.PARAMETER SkipHyperV
  Не включать Hyper-V и не показывать интерактивный запрос.

.PARAMETER SkipWinget
  Пропустить настройку WinGet и baseline-пакетов.

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

# В PowerShell 7+ native-команды могут автоматически подчиняться
# $ErrorActionPreference. Exit codes здесь обрабатываются явно.
# В Windows PowerShell 5.1 этой preference variable нет.
$getVariableParams = @{
  Name        = 'PSNativeCommandUseErrorActionPreference'
  ErrorAction = 'SilentlyContinue'
}

$nativePreferenceVariable = Get-Variable @getVariableParams

if ($null -ne $nativePreferenceVariable) {
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

$script:WingetBaselinePackages = @(
  @{
    Id     = 'Microsoft.WindowsTerminal'
    Action = 'upgrade'
  }
  @{
    Id     = 'Microsoft.PowerShell'
    Action = 'install'
  }
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
  [OutputType([string])]
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

  Write-Verbose "Executing: $FilePath $($Arguments -join ' ')"

  if ($Quiet) {
    & $FilePath @Arguments | Out-Null
  }
  else {
    # Native stdout не должен становиться output этой функции.
    & $FilePath @Arguments | Out-Host
  }

  $exitCode = $LASTEXITCODE

  if ($exitCode -in $SuccessExitCodes) {
    return $exitCode
  }

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

#region User Settings

function Set-WindowsMouseSettings {
  [CmdletBinding()]
  param(
    [ValidateRange(1, 20)]
    [int]$Speed = 6
  )

  Write-Step "Настройка мыши: speed=$Speed"

  $path = 'HKCU:\Control Panel\Mouse'

  Set-ItemProperty -Path $path -Name 'MouseSensitivity' -Value ([string]$Speed)
  Set-ItemProperty -Path $path -Name 'MouseSpeed' -Value '0'
  Set-ItemProperty -Path $path -Name 'MouseThreshold1' -Value '0'
  Set-ItemProperty -Path $path -Name 'MouseThreshold2' -Value '0'

  Write-Ok 'Настройки мыши применены'
}

function Set-WindowsKeyboardSettings {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка клавиатуры'

  Set-ItemProperty -Path 'HKCU:\Control Panel\Keyboard' -Name 'KeyboardDelay' -Value '0'

  Write-Ok 'Настройки клавиатуры применены'
}

#endregion User Settings

#region System Settings

function Set-WindowsRtcAsUtc {
  [CmdletBinding()]
  param()

  Write-Step 'Настройка RTC clock as UTC'

  $propertyParams = @{
    Path         = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
    Name         = 'RealTimeIsUniversal'
    Value        = 1
    PropertyType = 'DWord'
    Force        = $true
  }

  New-ItemProperty @propertyParams | Out-Null

  Write-Ok 'Windows настроена на использование RTC в UTC'
}

function Set-WindowsTimeSettings {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TimeZoneId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$NtpPeers
  )

  Write-Step "Настройка часового пояса: $TimeZoneId"

  Set-TimeZone -Id $TimeZoneId

  Write-Ok 'Часовой пояс настроен'
  Write-Step 'Настройка Windows Time Service'

  Set-Service -Name 'w32time' -StartupType Automatic
  Start-Service -Name 'w32time'

  $configuredPeers = @(
    foreach ($peer in $NtpPeers) {
      $peer = $peer.Trim()

      if ([string]::IsNullOrWhiteSpace($peer)) {
        continue
      }

      # Если флаги уже указаны пользователем, оставляем peer как есть.
      if ($peer -match ',0x[0-9A-Fa-f]+$') {
        $peer
        continue
      }

      # 0x8 = NTP client mode.
      "$peer,0x8"
    }
  )

  if ($configuredPeers.Count -eq 0) {
    throw 'Список NTP-серверов пуст.'
  }

  $peerList = $configuredPeers -join ' '
  $w32tmPath = Join-Path $env:SystemRoot 'System32\w32tm.exe'

  $configParams = @{
    FilePath  = $w32tmPath
    Arguments = @(
      '/config'
      "/manualpeerlist:$peerList"
      '/syncfromflags:manual'
      '/update'
    )
    Quiet     = $true
  }

  Invoke-NativeCommand @configParams | Out-Null

  Restart-Service -Name 'w32time'

  Write-Ok "NTP настроен: $($configuredPeers -join ', ')"

  try {
    $resyncParams = @{
      FilePath  = $w32tmPath
      Arguments = @('/resync')
      Quiet     = $true
    }

    Invoke-NativeCommand @resyncParams | Out-Null

    Write-Ok 'Время синхронизировано'
  }
  catch {
    # Конфигурация NTP уже применена. Отсутствие сети или временная
    # недоступность peer не должны считать весь bootstrap неуспешным.
    Write-Notice (
      'NTP настроен, но немедленная синхронизация не удалась: ' +
      $_.Exception.Message
    )
  }
}

#endregion System Settings

#region Windows Features

function Enable-WindowsHyperV {
  [CmdletBinding()]
  param()

  Write-Step 'Проверка Hyper-V'

  $getFeatureParams = @{
    Online      = $true
    FeatureName = 'Microsoft-Hyper-V'
    ErrorAction = 'Stop'
  }

  $feature = Get-WindowsOptionalFeature @getFeatureParams

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

  $enableFeatureParams = @{
    Online      = $true
    FeatureName = 'Microsoft-Hyper-V'
    All         = $true
    NoRestart   = $true
    ErrorAction = 'Stop'
  }

  $result = Enable-WindowsOptionalFeature @enableFeatureParams

  if ($result.RestartNeeded) {
    Write-Notice (
      'Hyper-V включён. Для завершения установки требуется перезагрузка.'
    )
    return
  }

  Write-Ok 'Hyper-V включён'
}

#endregion Windows Features

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

  $commandParams = @{
    FilePath         = $WingetPath
    Arguments        = $arguments
    SuccessExitCodes = $script:WingetAcceptedExitCodes
  }

  $exitCode = Invoke-NativeCommand @commandParams

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

  # Недостижимо при корректном WingetAcceptedExitCodes, но оставлено
  # как защита на случай расширения списка допустимых кодов.
  Write-Notice (
    "$Id завершён с допустимым кодом $(Format-ExitCode -ExitCode $exitCode)"
  )
}

function Enable-WingetProxyOption {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath
  )

  Write-Step 'Включение WinGet ProxyCommandLineOptions'

  $commandParams = @{
    FilePath  = $WingetPath
    Arguments = @(
      'settings'
      '--enable'
      'ProxyCommandLineOptions'
      '--disable-interactivity'
    )
    Quiet     = $true
  }

  Invoke-NativeCommand @commandParams | Out-Null

  Write-Ok 'WinGet ProxyCommandLineOptions включён'
}

function Initialize-WinGet {
  [CmdletBinding()]
  param()

  $getCommandParams = @{
    Name        = 'winget.exe'
    CommandType = 'Application'
    ErrorAction = 'SilentlyContinue'
  }

  $wingetCommand = Get-Command @getCommandParams

  if ($null -eq $wingetCommand) {
    throw (
      'winget.exe не найден. ' +
      'WinGet bootstrap не может быть выполнен.'
    )
  }

  $wingetPath = $wingetCommand.Source

  Write-Verbose "WinGet path: $wingetPath"

  # App Installer содержит сам WinGet client и обновляется первым.
  $appInstallerParams = @{
    WingetPath = $wingetPath
    Action     = 'upgrade'
    Id         = 'Microsoft.AppInstaller'
  }

  Invoke-WingetPackageAction @appInstallerParams

  # Системная prerequisite-настройка для Install-WingetPackages.ps1.
  Enable-WingetProxyOption -WingetPath $wingetPath

  foreach ($package in $script:WingetBaselinePackages) {
    $packageParams = @{
      WingetPath = $wingetPath
      Action     = $package.Action
      Id         = $package.Id
    }

    Invoke-WingetPackageAction @packageParams
  }
}

#endregion WinGet

#region Main

if ($EnableHyperV -and $SkipHyperV) {
  throw (
    'Параметры -EnableHyperV и -SkipHyperV ' +
    'нельзя использовать одновременно.'
  )
}

if ($PSCmdlet.ShouldProcess(
    'Current user mouse settings',
    "Set mouse speed to $MouseSpeed and disable acceleration"
  )) {
  Set-WindowsMouseSettings -Speed $MouseSpeed
}

if ($PSCmdlet.ShouldProcess(
    'Current user keyboard settings',
    'Set keyboard delay'
  )) {
  Set-WindowsKeyboardSettings
}

if ($PSCmdlet.ShouldProcess(
    'Windows RTC configuration',
    'Configure hardware clock as UTC'
  )) {
  Set-WindowsRtcAsUtc
}

if ($PSCmdlet.ShouldProcess(
    'Windows Time Service',
    "Configure timezone '$TimeZoneId' and NTP"
  )) {
  $timeParams = @{
    TimeZoneId = $TimeZoneId
    NtpPeers   = $NtpPeers
  }

  Set-WindowsTimeSettings @timeParams
}

if ($SkipWinget) {
  Write-Skip 'WinGet bootstrap пропущен'
}
elseif ($PSCmdlet.ShouldProcess(
    'WinGet',
    'Configure WinGet and baseline packages'
  )) {
  Initialize-WinGet
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
  $choiceParams = @{
    Title   = 'Hyper-V'
    Message = 'Включить Hyper-V?'
  }

  $shouldEnableHyperV = Confirm-Choice @choiceParams
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
