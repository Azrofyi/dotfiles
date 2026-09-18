#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
  Configures a personal Windows workstation after a clean installation.

.DESCRIPTION
  Intended for 64-bit Windows 11, starting with Windows PowerShell 5.1.
  Run elevated as the account you want to configure: HKCU settings and
  App Installer registration belong to the process user.

  Configures mouse and keyboard settings, the time zone and UTC hardware
  clock interpretation for dual boot. Synchronizes with the existing time
  source without changing NTP peers. Prepares WinGet and enables permission
  to use --proxy later; no proxy address is configured. Enables Hyper-V
  where available. App Installer must already be installed on the machine.

  PowerShell modules are installed separately with Install-PowerShellModules.ps1
  in PowerShell 7.4 or later. Profiles and application packages are managed
  separately.

  By default, asks whether to run each task (default: No). -All selects every
  task, including Hyper-V and UTC. -Confirm confirms related changes as one
  operation. -WhatIf previews tasks without applying configuration changes.

  Unexpected errors stop execution. Time synchronization failures and an
  unavailable Hyper-V feature produce warnings. Windows never restarts
  automatically; required restart/sign-out instructions are printed even
  if a later task fails.

.PARAMETER TimeZoneId
  Windows time zone ID. Default: Russian Standard Time.

.PARAMETER MouseSpeed
  Pointer speed on the registry/API scale of 1-20, not the legacy 11-position
  slider. Preserves the original default of 6 (Windows default: 10).
  Mouse acceleration is disabled.

.PARAMETER All
  Selects every task without the task-selection prompts. Does not override
  -WhatIf or an explicit -Confirm.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1
  Select tasks interactively.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -All -WhatIf
  Preview all tasks without applying configuration changes.

.EXAMPLE
  .\Invoke-WindowsBootstrap.ps1 -All
  Apply all tasks, including Hyper-V and UTC hardware clock interpretation.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateNotNullOrEmpty()]
  [string]$TimeZoneId = 'Russian Standard Time',

  [ValidateRange(1, 20)]
  [int]$MouseSpeed = 6,

  [switch]$All
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:restartRequired = $false
$script:signOutRequired = $false
$script:hadWarnings = $false

# Shared helpers for status, task selection and native exit codes.
function Write-Status {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('Step', 'Success', 'Skip', 'Warning')]
    [string]$Level,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if ($Level -eq 'Warning') {
    $script:hadWarnings = $true
    Write-Warning $Message
    return
  }

  $style = switch ($Level) {
    'Step' { @{ Prefix = '[*]'; Color = 'Cyan' } }
    'Success' { @{ Prefix = '[OK]'; Color = 'Green' } }
    'Skip' { @{ Prefix = '[SKIP]'; Color = 'Yellow' } }
  }
  Write-Host "$($style.Prefix) $Message" -ForegroundColor $style.Color
}

function Invoke-OptionalTask {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [scriptblock]$Action,

    [switch]$All
  )

  if (-not $All) {
    $choices = @(
      [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Run this task.')
      [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Skip this task.')
    )
    if ($Host.UI.PromptForChoice($Name, 'Run this task?', $choices, 1) -ne 0) {
      Write-Status -Level Skip -Message "$Name was skipped"
      return
    }
  }

  Write-Status -Level Step -Message $Name
  & $Action
}

function Invoke-NativeCommand {
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [string[]]$Arguments = @(),
    [int[]]$SuccessExitCodes = @(0)
  )

  # PowerShell 7 preference; a harmless local variable in 5.1.
  # Expected nonzero codes are handled explicitly below.
  $PSNativeCommandUseErrorActionPreference = $false
  Write-Verbose "Executing: $FilePath $($Arguments -join ' ')"

  # Preserve diagnostics, but keep stdout out of the returned exit code.
  & $FilePath @Arguments | Out-Host
  $exitCode = $LASTEXITCODE
  if ($null -eq $exitCode) {
    throw "$FilePath did not provide a process exit code."
  }
  if ($exitCode -notin $SuccessExitCodes) {
    $unsignedCode = if ($exitCode -lt 0) { [long]$exitCode + 4294967296 } else { [long]$exitCode }
    $hexCode = '0x{0:X8}' -f $unsignedCode
    throw "$FilePath exited with code $hexCode ($exitCode). Arguments: $($Arguments -join ' ')"
  }
  return [int]$exitCode
}

# Registry tasks share the same compare/confirm/write behavior.
function Set-RegistryValue {
  [CmdletBinding(SupportsShouldProcess)]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Values,

    [ValidateSet('String', 'DWord')]
    [string]$Type = 'String'
  )

  $key = if (Test-Path -LiteralPath $Path) { Get-Item -LiteralPath $Path } else { $null }
  $changedNames = @(
    foreach ($name in $Values.Keys) {
      if ($null -eq $key -or $null -eq $key.GetValue($name) -or
        $key.GetValue($name) -ne $Values[$name] -or $key.GetValueKind($name) -ne $Type) {
        $name
      }
    }
  )

  if ($changedNames.Count -eq 0) {
    Write-Status -Level Skip -Message 'Registry values are already configured'
    return $false
  }
  $changes = ($changedNames | ForEach-Object { "$_=$($Values[$_])" }) -join ', '
  if (-not $PSCmdlet.ShouldProcess($Path, "Set $Type values: $changes")) {
    return $false
  }

  if ($null -eq $key) {
    New-Item -Path $Path -Force -Confirm:$false | Out-Null
  }
  foreach ($name in $changedNames) {
    $propertyParams = @{
      LiteralPath  = $Path
      Name         = $name
      Value        = $Values[$name]
      PropertyType = $Type
      Force        = $true
      Confirm      = $false
    }
    New-ItemProperty @propertyParams | Out-Null
  }
  Write-Status -Level Success -Message 'Registry values were saved'
  return $true
}

function Set-WindowsTimeZone {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [string]$Id
  )

  if ((Get-TimeZone).Id -eq $Id) {
    Write-Status -Level Skip -Message "The time zone is already '$Id'"
    return
  }
  if ($PSCmdlet.ShouldProcess('System time zone', "Set time zone to '$Id'")) {
    Set-TimeZone -Id $Id -Confirm:$false
    Write-Status -Level Success -Message "The time zone was set to '$Id'"
  }
}

function Sync-WindowsTime {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  # One confirmation covers both the prerequisite and the dependent command.
  if (-not $PSCmdlet.ShouldProcess('Windows Time service',
      'Start if needed and synchronize with the existing time source')) {
    return
  }
  try {
    $service = Get-Service -Name 'w32time' -ErrorAction Stop
    if ($service.StartType -eq 'Disabled') {
      Write-Status -Level Warning -Message 'Windows Time is disabled. Check local or domain policy.'
      return
    }
    if ($service.Status -ne 'Running') {
      Start-Service -Name 'w32time' -Confirm:$false -ErrorAction Stop
    }
    $w32tmPath = Join-Path $env:SystemRoot 'System32\w32tm.exe'
    Invoke-NativeCommand -FilePath $w32tmPath -Arguments @('/resync', '/rediscover') | Out-Null
    Write-Status -Level Success -Message 'Windows time synchronization completed'
  }
  catch {
    Write-Status -Level Warning -Message "Time synchronization failed: $($_.Exception.Message)"
  }
}

function Initialize-WinGet {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if (-not $PSCmdlet.ShouldProcess('WinGet',
      'Register if needed, update App Installer and enable proxy command-line options')) {
    return
  }

  $wingetCommand = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
  if ($null -eq $wingetCommand) {
    # Appx may need Windows PowerShell compatibility when running in PS 7.
    if ($PSEdition -eq 'Core') {
      Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop
    }
    $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop
    if (-not $package) {
      throw 'App Installer is not installed. Install it from Microsoft, then rerun this task.'
    }
    $registrationParams = @{
      RegisterByFamilyName = $true
      MainPackage          = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
      ErrorAction          = 'Stop'
    }
    Add-AppxPackage @registrationParams
    $wingetCommand = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
      throw 'App Installer registration completed, but winget.exe is unavailable. Check its app execution alias and PATH, then reopen PowerShell.'
    }
  }

  # 0x8A15002B means no applicable update, not necessarily the newest release.
  $noApplicableUpdate = -1978335189
  $upgradeParams = @{
    FilePath         = $wingetCommand.Source
    Arguments        = @(
      'upgrade', '--id', 'Microsoft.AppInstaller', '--exact', '--source', 'winget',
      '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements'
    )
    SuccessExitCodes = @(0, $noApplicableUpdate)
  }
  $exitCode = Invoke-NativeCommand @upgradeParams
  if ($exitCode -eq $noApplicableUpdate) {
    Write-Status -Level Skip -Message 'No applicable WinGet client update was found'
  }
  else {
    Write-Status -Level Success -Message 'The WinGet client was updated'
  }

  $wingetCommand = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
  if ($null -eq $wingetCommand) {
    throw 'winget.exe is unavailable after the update. Reopen PowerShell and rerun this task.'
  }
  $arguments = @('settings', '--enable', 'ProxyCommandLineOptions', '--disable-interactivity')
  Invoke-NativeCommand -FilePath $wingetCommand.Source -Arguments $arguments | Out-Null
  Write-Status -Level Success -Message 'WinGet permits --proxy and --no-proxy; no proxy address was configured'
}

function Enable-WindowsHyperV {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $featureName = 'Microsoft-Hyper-V'
  # Enumerating first distinguishes an unavailable feature from a DISM error.
  $feature = Get-WindowsOptionalFeature -Online -ErrorAction Stop |
  Where-Object FeatureName -eq $featureName
  if (-not $feature) {
    Write-Status -Level Warning -Message 'Hyper-V is unavailable in this Windows edition/image.'
    return
  }
  switch ($feature.State) {
    'Enabled' {
      Write-Status -Level Skip -Message 'Hyper-V is already enabled'
      return
    }
    'EnablePending' {
      $script:restartRequired = $true
      Write-Status -Level Skip -Message 'Hyper-V is already pending activation'
      return
    }
    'DisablePending' {
      $script:restartRequired = $true
      throw 'Hyper-V is pending removal. Restart Windows before enabling it again.'
    }
  }
  if (-not $PSCmdlet.ShouldProcess('Hyper-V', 'Enable Windows optional feature without restarting')) {
    return
  }

  # DISM does not support -Confirm; the enclosing ShouldProcess is the guard.
  $featureParams = @{
    Online      = $true
    FeatureName = $featureName
    All         = $true
    NoRestart   = $true
    ErrorAction = 'Stop'
  }
  $result = Enable-WindowsOptionalFeature @featureParams
  $script:restartRequired = $script:restartRequired -or $result.RestartNeeded
  Write-Status -Level Success -Message 'Hyper-V was enabled'
}

function Enable-WindowsSandbox {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $featureName = 'Containers-DisposableClientVM'

  $feature = Get-WindowsOptionalFeature -Online -ErrorAction Stop |
  Where-Object FeatureName -eq $featureName

  if (-not $feature) {
    Write-Status -Level Warning -Message 'Windows Sandbox is unavailable in this Windows edition/image.'
    return
  }

  switch ($feature.State) {
    'Enabled' {
      Write-Status -Level Skip -Message 'Windows Sandbox is already enabled'
      return
    }

    'EnablePending' {
      $script:restartRequired = $true
      Write-Status -Level Skip -Message 'Windows Sandbox is already pending activation'
      return
    }

    'DisablePending' {
      $script:restartRequired = $true
      throw 'Windows Sandbox is pending removal. Restart Windows before enabling it again.'
    }
  }

  if (-not $PSCmdlet.ShouldProcess(
      'Windows Sandbox',
      'Enable Windows optional feature without restarting'
    )) {
    return
  }

  $result = Enable-WindowsOptionalFeature `
    -Online `
    -FeatureName $featureName `
    -All `
    -NoRestart `
    -ErrorAction Stop

  $script:restartRequired = $script:restartRequired -or $result.RestartNeeded

  Write-Status -Level Success -Message 'Windows Sandbox was enabled'
}

# Validate local prerequisites before any configuration changes.
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw 'This script requires Windows.'
}
if (-not [Environment]::Is64BitProcess) {
  throw 'Run this script in 64-bit PowerShell.'
}
[TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId) | Out-Null
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Status -Level Step -Message "User: $currentUser; PowerShell $($PSVersionTable.PSVersion) ($PSEdition)"
Write-Host 'HKCU settings and App Installer registration target this account.'

# Tasks stay in execution order; registry settings are kept next to their task.
try {
  Invoke-OptionalTask -Name 'Mouse configuration' -All:$All -Action {
    $values = [ordered]@{
      MouseSensitivity = [string]$MouseSpeed
      MouseSpeed       = '0'
      MouseThreshold1  = '0'
      MouseThreshold2  = '0'
    }
    if (Set-RegistryValue -Path 'HKCU:\Control Panel\Mouse' -Values $values) {
      $script:signOutRequired = $true
    }
  }

  Invoke-OptionalTask -Name 'Keyboard configuration' -All:$All -Action {
    if (Set-RegistryValue -Path 'HKCU:\Control Panel\Keyboard' -Values @{ KeyboardDelay = '0' }) {
      $script:signOutRequired = $true
    }
  }

  Invoke-OptionalTask -Name 'Time zone configuration' -All:$All -Action {
    Set-WindowsTimeZone -Id $TimeZoneId
  }

  Invoke-OptionalTask -Name 'UTC hardware clock configuration' -All:$All -Action {
    $registryParams = @{
      Path   = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
      Values = @{ RealTimeIsUniversal = 1 }
      Type   = 'DWord'
    }
    if (Set-RegistryValue @registryParams) {
      $script:restartRequired = $true
    }
  }

  Invoke-OptionalTask -Name 'Time synchronization' -All:$All -Action {
    Sync-WindowsTime
  }

  Invoke-OptionalTask -Name 'WinGet bootstrap' -All:$All -Action {
    Initialize-WinGet
  }

  Invoke-OptionalTask -Name 'Hyper-V' -All:$All -Action {
    Enable-WindowsHyperV
  }

  Invoke-OptionalTask -Name 'Enable-WindowsSandbox' -All:$All -Action {
    Enable-WindowsSandbox
  }

  if ($WhatIfPreference) {
    Write-Status -Level Success -Message 'WhatIf preview completed; no configuration changes were applied'
  }
  elseif ($script:hadWarnings) {
    Write-Status -Level Warning -Message 'Windows bootstrap finished with warnings; review the messages above'
  }
  else {
    Write-Status -Level Success -Message 'Windows bootstrap completed successfully'
  }
}
finally {
  if (-not $WhatIfPreference) {
    if ($script:restartRequired) {
      Write-Host 'Restart Windows to finish applying the changes.' -ForegroundColor Yellow
    }
    elseif ($script:signOutRequired) {
      Write-Host 'Sign out and back in to apply mouse/keyboard settings.' -ForegroundColor Yellow
    }
  }
}
