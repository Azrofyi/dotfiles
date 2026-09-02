#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
  Applies a baseline configuration to a Windows workstation.

.DESCRIPTION
  Configures the current user's mouse and keyboard settings, sets the Windows
  time zone, synchronizes time using the existing Windows time source,
  configures the hardware clock as UTC for dual-boot compatibility, prepares
  WinGet, enables its proxy command-line options, and optionally enables
  Hyper-V. Application installation is intentionally handled by the separate
  Install-WinGetPackages.ps1 script.

  By default, the script asks whether to run each configuration task. Use -All
  to run every task without selection prompts. The script is safe to run more
  than once, checks the current state before changing Windows settings, and
  supports -WhatIf and -Confirm.

  NTP peers are deliberately left unchanged. Standalone computers can use the
  Windows default time source, while domain-joined computers should normally
  synchronize through the Active Directory domain hierarchy.

.PARAMETER TimeZoneId
  Windows time zone identifier. The default is Russian Standard Time.

.PARAMETER MouseSpeed
  Mouse pointer speed from 1 through 20. Mouse acceleration is disabled.

.PARAMETER All
  Runs every configuration task without selection prompts. This includes
  enabling Hyper-V.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1

  Interactively asks whether to run each configuration task.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -All

  Runs every configuration task without selection prompts.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -All -WhatIf

  Previews every configuration task without selection prompts.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -TimeZoneId 'Russian Standard Time' -MouseSpeed 6

  Uses custom values while interactively selecting configuration tasks.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
  [ValidateNotNullOrEmpty()]
  [string]$TimeZoneId = 'Russian Standard Time',

  [ValidateRange(1, 20)]
  [int]$MouseSpeed = 6,

  [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 7 can turn a nonzero native exit code into a PowerShell error.
# Exit codes are handled explicitly below so Windows PowerShell 5.1 and
# PowerShell 7 behave consistently.
$nativeErrorPreference = Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -ErrorAction SilentlyContinue

if ($null -ne $nativeErrorPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$script:WingetUpdateNotApplicableExitCode = -1978335189 # 0x8A15002B

function Write-Status {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('Step', 'Success', 'Skip', 'Warning')]
    [string]$Level,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Message
  )

  $style = switch ($Level) {
    'Step' { @{ Prefix = '[*]'; Color = [ConsoleColor]::Cyan } }
    'Success' { @{ Prefix = '[OK]'; Color = [ConsoleColor]::Green } }
    'Skip' { @{ Prefix = '[SKIP]'; Color = [ConsoleColor]::Yellow } }
    'Warning' { @{ Prefix = '[!]'; Color = [ConsoleColor]::Yellow } }
  }

  Write-Host "$($style.Prefix) $Message" -ForegroundColor $style.Color
}

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

    [ValidateNotNullOrEmpty()]
    [int[]]$SuccessExitCodes = @(0),

    [switch]$Quiet
  )

  Write-Verbose "Executing: $FilePath $($Arguments -join ' ')"

  if ($Quiet) {
    & $FilePath @Arguments | Out-Null
  }
  else {
    # Keep native stdout out of this function's success output stream.
    & $FilePath @Arguments | Out-Host
  }

  if ($null -eq $LASTEXITCODE) {
    throw "$FilePath did not provide a process exit code."
  }

  $exitCode = [int]$LASTEXITCODE

  if ($exitCode -in $SuccessExitCodes) {
    return $exitCode
  }

  $formattedCode = Format-ExitCode -ExitCode $exitCode
  throw "$FilePath exited with code $formattedCode ($exitCode). Arguments: $($Arguments -join ' ')"
}

function Confirm-Choice {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Message,

    [bool]$Default = $false
  )

  $choices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&Yes',
      'Perform the operation.'
    )
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&No',
      'Skip the operation.'
    )
  )

  $defaultChoice = if ($Default) { 0 } else { 1 }
  $choice = $Host.UI.PromptForChoice($Title, $Message, $choices, $defaultChoice)

  return $choice -eq 0
}

function Invoke-OptionalTask {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory)]
    [scriptblock]$Action,

    [switch]$All
  )

  $selected = $All.IsPresent

  if (-not $selected) {
    $selected = Confirm-Choice -Title $Name -Message 'Run this task?'
  }

  if (-not $selected) {
    Write-Status -Level Skip -Message "$Name was skipped"
    return
  }

  & $Action
}

function Set-WindowsMouseConfiguration {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [ValidateRange(1, 20)]
    [int]$Speed = 6
  )

  $path = 'HKCU:\Control Panel\Mouse'
  $desiredSettings = [ordered]@{
    MouseSensitivity = [string]$Speed
    MouseSpeed       = '0'
    MouseThreshold1  = '0'
    MouseThreshold2  = '0'
  }

  $currentSettings = Get-ItemProperty -Path $path
  $changeRequired = $false

  foreach ($setting in $desiredSettings.GetEnumerator()) {
    $currentProperty = $currentSettings.PSObject.Properties[$setting.Key]

    if (
      $null -eq $currentProperty -or
      [string]$currentProperty.Value -ne [string]$setting.Value
    ) {
      $changeRequired = $true
      break
    }
  }

  if (-not $changeRequired) {
    Write-Status -Level Skip -Message 'Mouse settings are already configured'
    return
  }

  $action = "Set pointer speed to $Speed and disable mouse acceleration"

  if (-not $PSCmdlet.ShouldProcess($path, $action)) {
    return
  }

  Write-Status -Level Step -Message 'Configuring mouse settings'

  foreach ($setting in $desiredSettings.GetEnumerator()) {
    Set-ItemProperty -Path $path -Name $setting.Key -Value $setting.Value -Confirm:$false
  }

  Write-Status -Level Success -Message 'Mouse settings were configured'
}

function Set-WindowsKeyboardConfiguration {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $path = 'HKCU:\Control Panel\Keyboard'
  $name = 'KeyboardDelay'
  $desiredValue = '0'
  $currentValue = Get-ItemPropertyValue -Path $path -Name $name

  if ([string]$currentValue -eq $desiredValue) {
    Write-Status -Level Skip -Message 'Keyboard settings are already configured'
    return
  }

  if (-not $PSCmdlet.ShouldProcess($path, "Set $name to $desiredValue")) {
    return
  }

  Write-Status -Level Step -Message 'Configuring keyboard settings'
  Set-ItemProperty -Path $path -Name $name -Value $desiredValue -Confirm:$false
  Write-Status -Level Success -Message 'Keyboard settings were configured'
}

function Set-WindowsHardwareClockToUtc {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
  $name = 'RealTimeIsUniversal'
  $currentValue = Get-ItemPropertyValue -Path $path -Name $name -ErrorAction SilentlyContinue

  if ($currentValue -eq 1) {
    Write-Status -Level Skip -Message 'The hardware clock is already interpreted as UTC'
    return
  }

  if (-not $PSCmdlet.ShouldProcess($path, "Set $name to 1")) {
    return
  }

  Write-Status -Level Step -Message 'Configuring Windows to interpret the hardware clock as UTC'

  $propertyParams = @{
    Path         = $path
    Name         = $name
    Value        = 1
    PropertyType = 'DWord'
    Force        = $true
    Confirm      = $false
  }

  New-ItemProperty @propertyParams | Out-Null
  Write-Status -Level Success -Message 'The hardware clock is now interpreted as UTC'
}

function Set-WindowsTimeZone {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Id
  )

  $currentTimeZone = Get-TimeZone

  if ($currentTimeZone.Id -eq $Id) {
    Write-Status -Level Skip -Message "The time zone is already set to '$Id'"
    return
  }

  $action = "Change time zone from '$($currentTimeZone.Id)' to '$Id'"

  if (-not $PSCmdlet.ShouldProcess('System time zone', $action)) {
    return
  }

  Write-Status -Level Step -Message "Setting the time zone to '$Id'"
  Set-TimeZone -Id $Id -Confirm:$false
  Write-Status -Level Success -Message "The time zone was set to '$Id'"
}

function Sync-WindowsTime {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $service = Get-Service -Name 'w32time' -ErrorAction Stop

  if ($service.StartType -eq 'Disabled') {
    $message = 'The Windows Time service is disabled. Check local or domain policy before enabling it.'
    Write-Status -Level Warning -Message $message
    return
  }

  if ($service.Status -ne 'Running') {
    if ($PSCmdlet.ShouldProcess('Windows Time service', 'Start service')) {
      Write-Status -Level Step -Message 'Starting the Windows Time service'
      Start-Service -Name 'w32time' -Confirm:$false
    }
  }

  if (-not $PSCmdlet.ShouldProcess(
      'Windows Time service',
      'Rediscover the configured time source and synchronize time'
    )) {
    return
  }

  Write-Status -Level Step -Message 'Synchronizing time using the configured Windows time source'

  $w32tmPath = Join-Path $env:SystemRoot 'System32\w32tm.exe'

  try {
    Invoke-NativeCommand -FilePath $w32tmPath -Arguments @('/resync', '/rediscover') -Quiet | Out-Null
    Write-Status -Level Success -Message 'Windows time synchronization completed'
  }
  catch {
    # A temporary network or time-source failure should not invalidate the
    # remaining workstation configuration.
    Write-Status -Level Warning -Message "Immediate time synchronization failed: $($_.Exception.Message)"
  }
}

function Enable-WindowsHyperV {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([bool])]
  param()

  $featureName = 'Microsoft-Hyper-V'
  $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop

  if ($feature.State -eq 'Enabled') {
    Write-Status -Level Skip -Message 'Hyper-V is already enabled'
    return $false
  }

  if ($feature.State -eq 'EnablePending') {
    Write-Status -Level Warning -Message 'Hyper-V is pending activation and requires a restart'
    return $true
  }

  if (-not $PSCmdlet.ShouldProcess('Hyper-V', 'Enable Windows optional feature')) {
    return $false
  }

  Write-Status -Level Step -Message 'Enabling Hyper-V'

  $featureParams = @{
    Online      = $true
    FeatureName = $featureName
    All         = $true
    NoRestart   = $true
    ErrorAction = 'Stop'
    Confirm     = $false
  }

  $result = Enable-WindowsOptionalFeature @featureParams

  if ($result.RestartNeeded) {
    Write-Status -Level Success -Message 'Hyper-V was enabled and requires a restart'
    return $true
  }

  Write-Status -Level Success -Message 'Hyper-V was enabled'
  return $false
}

function Get-WinGetPath {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $wingetCommand = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue

  if ($null -eq $wingetCommand) {
    return $null
  }

  return $wingetCommand.Source
}

function Register-WinGet {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess(
      'App Installer',
      'Register WinGet for the current user'
    )) {
    return
  }

  Write-Status -Level Step -Message 'Registering App Installer for the current user'

  try {
    $packageName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    Add-AppxPackage -RegisterByFamilyName -MainPackage $packageName -ErrorAction Stop
  }
  catch {
    throw ('WinGet was not found and App Installer registration failed. ' + $_.Exception.Message)
  }

  Write-Status -Level Success -Message 'App Installer was registered successfully'
}

function Update-WinGetClient {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath
  )

  $packageId = 'Microsoft.AppInstaller'

  if (-not $PSCmdlet.ShouldProcess($packageId, 'Update the WinGet client')) {
    return
  }

  Write-Status -Level Step -Message 'Checking for a WinGet client update'

  $arguments = @(
    'upgrade'
    '--id'
    $packageId
    '--exact'
    '--source'
    'winget'
    '--silent'
    '--disable-interactivity'
    '--accept-source-agreements'
    '--accept-package-agreements'
  )

  $successExitCodes = @(
    0
    $script:WingetUpdateNotApplicableExitCode
  )

  $commandParams = @{
    FilePath         = $WingetPath
    Arguments        = $arguments
    SuccessExitCodes = $successExitCodes
  }

  $exitCode = Invoke-NativeCommand @commandParams

  switch ($exitCode) {
    0 {
      Write-Status -Level Success -Message 'The WinGet client was updated successfully'
    }
    { $_ -eq $script:WingetUpdateNotApplicableExitCode } {
      Write-Status -Level Skip -Message 'The WinGet client is already up to date'
    }
  }
}

function Enable-WinGetProxyCommandLineOption {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath
  )

  $settingName = 'ProxyCommandLineOptions'

  if (-not $PSCmdlet.ShouldProcess('WinGet', "Enable $settingName")) {
    return
  }

  Write-Status -Level Step -Message "Enabling the WinGet $settingName setting"

  $arguments = @(
    'settings'
    '--enable'
    $settingName
    '--disable-interactivity'
  )

  Invoke-NativeCommand -FilePath $WingetPath -Arguments $arguments -Quiet | Out-Null
  Write-Status -Level Success -Message "The WinGet $settingName setting was enabled"
}

function Initialize-WinGet {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $wingetPath = Get-WinGetPath

  if ([string]::IsNullOrWhiteSpace($wingetPath)) {
    Write-Status -Level Step -Message 'WinGet was not found; attempting App Installer registration'
    Register-WinGet
    $wingetPath = Get-WinGetPath

    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
      if ($WhatIfPreference) {
        Write-Status -Level Warning -Message 'Further WinGet changes require WinGet to be available'
        return
      }

      throw 'App Installer was registered, but winget.exe is still unavailable in the current session.'
    }
  }

  Write-Verbose "WinGet path: $wingetPath"

  # App Installer contains the WinGet client and is updated before its settings
  # are configured.
  Update-WinGetClient -WingetPath $wingetPath

  # Resolve the app execution alias again after updating App Installer.
  $wingetPath = Get-WinGetPath

  Enable-WinGetProxyCommandLineOption -WingetPath $wingetPath
}

Invoke-OptionalTask -Name 'Mouse configuration' -All:$All -Action {
  Set-WindowsMouseConfiguration -Speed $MouseSpeed
}

Invoke-OptionalTask -Name 'Keyboard configuration' -All:$All -Action {
  Set-WindowsKeyboardConfiguration
}

Invoke-OptionalTask -Name 'Time zone configuration' -All:$All -Action {
  Set-WindowsTimeZone -Id $TimeZoneId
}

Invoke-OptionalTask -Name 'Time synchronization' -All:$All -Action {
  Sync-WindowsTime
}

Invoke-OptionalTask -Name 'UTC hardware clock configuration' -All:$All -Action {
  Set-WindowsHardwareClockToUtc
}

Invoke-OptionalTask -Name 'WinGet bootstrap' -All:$All -Action {
  Initialize-WinGet
}

$rebootRequired = [bool](
  Invoke-OptionalTask -Name 'Hyper-V' -All:$All -Action {
    Enable-WindowsHyperV
  }
)

if ($WhatIfPreference) {
  Write-Status -Level Success -Message 'The WhatIf evaluation completed successfully'
}
else {
  Write-Status -Level Success -Message 'Windows bootstrap completed successfully'

  if ($rebootRequired) {
    Write-Status -Level Warning -Message 'Restart Windows to complete the requested changes'
  }
}
