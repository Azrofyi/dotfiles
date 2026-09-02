#requires -Version 5.1

<#
.SYNOPSIS
    Installs applications from declarative WinGet profiles.

.DESCRIPTION
    Loads a package catalog and profiles from packages.psd1, resolves an
    installation plan, executes WinGet, and returns structured result objects.

    Packages that require a proxy are skipped when -Proxy is not specified.
    The script never prompts for proxy settings.

.EXAMPLE
    .\Install-WinGetPackages.ps1

    Installs the Default profile.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Profile Default,Optional

    Installs the union of the Default and Optional profiles.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Profile @() -IncludePackage Git,VSCode

    Installs only Git and Visual Studio Code.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -ExcludePackage DockerDesktop,Discord

    Installs the Default profile except Docker Desktop and Discord.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Proxy 'http://127.0.0.1:10809'

    Uses the specified proxy only for packages configured with Network=Proxy.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Profile Default,Trial -WhatIf

    Displays the resolved plan without installing packages.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
  [AllowEmptyCollection()]
  [string[]]$Profile,

  [Alias('Include')]
  [AllowEmptyCollection()]
  [string[]]$IncludePackage,

  [Alias('Exclude')]
  [AllowEmptyCollection()]
  [string[]]$ExcludePackage,

  [string]$Proxy,

  [ValidateNotNullOrEmpty()]
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'packages.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 7 can turn non-zero native exit codes into PowerShell errors.
# WinGet exit codes are interpreted explicitly by this script.
$nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue

if ($null -ne $nativeErrorPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$script:WingetNoChangeExitCodes = @(
  -1978335189 # 0x8A15002B: update not applicable
  -1978335135 # 0x8A150061: package already installed
)


function Show-Section {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Title
  )

  Write-Host ''
  Write-Host "========== $Title ==========" -ForegroundColor White
}


function Get-CleanValues {
  [CmdletBinding()]
  param(
    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$Value
  )

  foreach ($item in @($Value)) {
    if (-not [string]::IsNullOrWhiteSpace($item)) {
      $item.Trim()
    }
  }
}


function Import-PackageConfiguration {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Configuration file not found: $Path"
  }

  $rawConfig = Import-PowerShellDataFile -LiteralPath $Path

  foreach ($section in @('Defaults', 'Catalog', 'Profiles')) {
    if (-not $rawConfig.ContainsKey($section)) {
      throw "Configuration section '$section' is missing."
    }

    if ($rawConfig[$section] -isnot [System.Collections.IDictionary]) {
      throw "Configuration section '$section' must be a hashtable."
    }
  }

  $defaults = $rawConfig.Defaults

  foreach ($property in @('Source', 'Network')) {
    if (-not $defaults.ContainsKey($property)) {
      throw "Required property 'Defaults.$property' is missing."
    }

    if ([string]::IsNullOrWhiteSpace([string]$defaults[$property])) {
      throw "Defaults.$property cannot be empty."
    }
  }

  $defaultSource = ([string]$defaults['Source']).Trim()
  $defaultNetwork = ([string]$defaults['Network']).Trim()

  if ($defaultNetwork -notin @('Default', 'Proxy')) {
    throw "Defaults.Network must be either 'Default' or 'Proxy'."
  }

  if ($rawConfig.Catalog.Count -eq 0) {
    throw 'The Catalog section cannot be empty.'
  }

  if ($rawConfig.Profiles.Count -eq 0) {
    throw 'The Profiles section cannot be empty.'
  }

  $catalog = @{}
  $managedArgumentNames = @(
    '--accept-package-agreements'
    '--accept-source-agreements'
    '--disable-interactivity'
    '--exact'
    '--id'
    '--no-proxy'
    '--proxy'
    '--silent'
    '--source'
  )

  foreach ($key in $rawConfig.Catalog.Keys) {
    $item = $rawConfig.Catalog[$key]

    if ([string]::IsNullOrWhiteSpace([string]$key)) {
      throw 'A catalog entry with an empty logical key was found.'
    }

    if ($item -isnot [System.Collections.IDictionary]) {
      throw "Catalog entry '$key' must be a hashtable."
    }

    if (-not $item.Contains('Id')) {
      throw "Catalog entry '$key' does not have an Id."
    }

    $id = ([string]$item['Id']).Trim()

    if ([string]::IsNullOrWhiteSpace($id)) {
      throw "Catalog entry '$key' does not have an Id."
    }

    $name = if ($item.Contains('Name') -and -not [string]::IsNullOrWhiteSpace([string]$item['Name'])) {
      ([string]$item['Name']).Trim()
    }
    else {
      [string]$key
    }

    $source = if ($item.Contains('Source')) {
      ([string]$item['Source']).Trim()
    }
    else {
      $defaultSource
    }

    $network = if ($item.Contains('Network')) {
      ([string]$item['Network']).Trim()
    }
    else {
      $defaultNetwork
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
      throw "Package '$key' does not have a Source."
    }

    if ($network -notin @('Default', 'Proxy')) {
      throw "Package '$key' has an unknown Network value '$network'."
    }

    $additionalArgs = @()

    if ($item.Contains('AdditionalArgs') -and $null -ne $item['AdditionalArgs']) {
      $additionalArgs = @(
        $item['AdditionalArgs'] |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
    }

    $managedArguments = @(
      $additionalArgs |
      ForEach-Object { ($_ -split '=', 2)[0].ToLowerInvariant() } |
      Where-Object { $_ -in $managedArgumentNames } |
      Select-Object -Unique
    )

    if ($managedArguments.Count -gt 0) {
      throw "Package '$key' uses arguments managed by the script: $($managedArguments -join ', ')"
    }

    $catalog[[string]$key] = [pscustomobject]@{
      Key            = [string]$key
      Id             = $id
      Name           = $name
      Source         = $source
      Network        = $network
      AdditionalArgs = $additionalArgs
    }
  }

  $duplicatePackages = @(
    $catalog.Values |
    Group-Object { '{0}:{1}' -f $_.Source, $_.Id } |
    Where-Object Count -gt 1
  )

  if ($duplicatePackages.Count -gt 0) {
    throw "Duplicate package definitions found: $($duplicatePackages.Name -join ', ')"
  }

  $profiles = @{}

  foreach ($profileName in $rawConfig.Profiles.Keys) {
    if ([string]::IsNullOrWhiteSpace([string]$profileName)) {
      throw 'A profile with an empty name was found.'
    }

    $packageKeys = @(Get-CleanValues -Value @($rawConfig.Profiles[$profileName]))
    $unknownKeys = @($packageKeys | Where-Object { -not $catalog.ContainsKey($_) })

    if ($unknownKeys.Count -gt 0) {
      throw "Profile '$profileName' references unknown packages: $($unknownKeys -join ', ')"
    }

    $duplicateKeys = @($packageKeys | Group-Object | Where-Object Count -gt 1)

    if ($duplicateKeys.Count -gt 0) {
      throw "Profile '$profileName' contains duplicate packages: $($duplicateKeys.Name -join ', ')"
    }

    $profiles[[string]$profileName] = $packageKeys
  }

  [pscustomobject]@{
    Catalog  = $catalog
    Profiles = $profiles
  }
}


function Resolve-PackageKeys {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Configuration,

    [AllowEmptyCollection()]
    [string[]]$RequestedProfiles,

    [AllowEmptyCollection()]
    [string[]]$Include,

    [AllowEmptyCollection()]
    [string[]]$Exclude
  )

  $requestedProfiles = @(Get-CleanValues -Value $RequestedProfiles)
  $includedKeys = @(Get-CleanValues -Value $Include)
  $excludedKeys = @(Get-CleanValues -Value $Exclude)
  $availableProfiles = @($Configuration.Profiles.Keys)
  $availablePackages = @($Configuration.Catalog.Keys)

  $unknownProfiles = @($requestedProfiles | Where-Object { $_ -notin $availableProfiles })

  if ($unknownProfiles.Count -gt 0) {
    throw "Unknown profiles: $($unknownProfiles -join ', '). Available profiles: $($availableProfiles -join ', ')"
  }

  $unknownPackages = @(
    @($includedKeys + $excludedKeys) |
    Where-Object { $_ -notin $availablePackages } |
    Select-Object -Unique
  )

  if ($unknownPackages.Count -gt 0) {
    throw "Unknown package keys: $($unknownPackages -join ', ')"
  }

  $selectedKeys = @()

  foreach ($profileName in $requestedProfiles) {
    foreach ($key in @($Configuration.Profiles[$profileName])) {
      if ($key -notin $selectedKeys) {
        $selectedKeys += $key
      }
    }
  }

  foreach ($key in $includedKeys) {
    if ($key -notin $selectedKeys) {
      $selectedKeys += $key
    }
  }

  @($selectedKeys | Where-Object { $_ -notin $excludedKeys })
}


function New-WingetArguments {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Package,

    [string]$Proxy
  )

  $wingetArgs = @(
    'install'
    '--id'
    $Package.Id
    '--source'
    $Package.Source
  )

  # Microsoft Store IDs are already unique and do not need --exact.
  if ($Package.Source -ne 'msstore') {
    $wingetArgs += '--exact'
  }

  $wingetArgs += @(
    '--silent'
    '--disable-interactivity'
    '--accept-source-agreements'
    '--accept-package-agreements'
  )

  if ($Package.Network -eq 'Proxy') {
    $wingetArgs += @('--proxy', $Proxy)
  }

  if ($Package.AdditionalArgs.Count -gt 0) {
    $wingetArgs += $Package.AdditionalArgs
  }

  $wingetArgs
}


function New-InstallationPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Configuration,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$PackageKey,

    [string]$Proxy
  )

  $resolvedProxy = if ([string]::IsNullOrWhiteSpace($Proxy)) {
    $null
  }
  else {
    $Proxy.Trim()
  }

  foreach ($key in $PackageKey) {
    $package = $Configuration.Catalog[$key]
    $missingProxy = $package.Network -eq 'Proxy' -and $null -eq $resolvedProxy

    [pscustomobject]@{
      Key       = $package.Key
      Id        = $package.Id
      Name      = $package.Name
      Source    = $package.Source
      Network   = $package.Network
      Action    = if ($missingProxy) { 'Skip' } else { 'Install' }
      Reason    = if ($missingProxy) { 'Proxy was not specified.' } else { $null }
      Arguments = if ($missingProxy) {
        @()
      }
      else {
        @(New-WingetArguments -Package $package -Proxy $resolvedProxy)
      }
    }
  }
}


function Show-InstallationPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Plan
  )

  Show-Section -Title 'Installation plan'

  if ($Plan.Count -eq 0) {
    Write-Host 'No packages selected.' -ForegroundColor Yellow
    return
  }

  foreach ($item in $Plan) {
    if ($item.Action -eq 'Install') {
      Write-Host "  + $($item.Name) [$($item.Key)] source=$($item.Source), network=$($item.Network)" -ForegroundColor Cyan
    }
    else {
      Write-Host "  - $($item.Name) [$($item.Key)] skipped: $($item.Reason)" -ForegroundColor Yellow
    }
  }
}


function Get-WingetPath {
  [CmdletBinding()]
  param()

  $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue

  if ($null -eq $command) {
    throw 'winget.exe was not found.'
  }

  $command.Source
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

  '0x{0:X8}' -f $unsignedCode
}


function New-InstallResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$PlanItem,

    [Parameter(Mandatory)]
    [string]$Status,

    [AllowNull()]
    [Nullable[int]]$ExitCode,

    [AllowNull()]
    [Nullable[timespan]]$Duration,

    [string]$Reason
  )

  [pscustomobject]@{
    Key         = $PlanItem.Key
    Id          = $PlanItem.Id
    Name        = $PlanItem.Name
    Source      = $PlanItem.Source
    Network     = $PlanItem.Network
    Status      = $Status
    ExitCode    = $ExitCode
    ExitCodeHex = if ($null -eq $ExitCode) { $null } else { Format-ExitCode -ExitCode $ExitCode }
    Duration    = $Duration
    Reason      = $Reason
  }
}


function Install-WingetPlanItem {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$PlanItem,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath
  )

  $installLabel = if ($PlanItem.Network -eq 'Proxy') {
    '[*] Installing via proxy'
  }
  else {
    '[*] Installing'
  }

  Write-Host "${installLabel}: $($PlanItem.Name) [$($PlanItem.Id)]" -ForegroundColor Cyan

  $startedAt = Get-Date
  $wingetArgs = [string[]]$PlanItem.Arguments

  # Keep native stdout visible without mixing it with structured results.
  & $WingetPath @wingetArgs | Out-Host

  $exitCode = $LASTEXITCODE
  $duration = (Get-Date) - $startedAt

  if ($exitCode -eq 0) {
    Write-Host "[OK] $($PlanItem.Name)" -ForegroundColor Green
    New-InstallResult -PlanItem $PlanItem -Status 'Succeeded' -ExitCode $exitCode -Duration $duration
    return
  }

  if ($exitCode -in $script:WingetNoChangeExitCodes) {
    Write-Host "[CURRENT] $($PlanItem.Name) is already installed or up to date." -ForegroundColor DarkGreen
    New-InstallResult -PlanItem $PlanItem -Status 'Current' -ExitCode $exitCode -Duration $duration
    return
  }

  $formattedCode = Format-ExitCode -ExitCode $exitCode
  Write-Warning "[FAILED] $($PlanItem.Name): $formattedCode ($exitCode)"
  New-InstallResult -PlanItem $PlanItem -Status 'Failed' -ExitCode $exitCode -Duration $duration
}


function Show-InstallSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results
  )

  Show-Section -Title 'Summary'

  if ($Results.Count -eq 0) {
    Write-Host 'No packages selected.' -ForegroundColor Yellow
    return
  }

  $succeeded = @($Results | Where-Object Status -eq 'Succeeded')
  $current = @($Results | Where-Object Status -eq 'Current')
  $skipped = @($Results | Where-Object Status -eq 'Skipped')
  $notRun = @($Results | Where-Object Status -eq 'NotRun')
  $failed = @($Results | Where-Object Status -eq 'Failed')

  Write-Host "Installed: $($succeeded.Count)" -ForegroundColor Green
  Write-Host "Already current: $($current.Count)" -ForegroundColor Green
  Write-Host "Skipped: $($skipped.Count)" -ForegroundColor Yellow
  Write-Host "Not run: $($notRun.Count)" -ForegroundColor DarkYellow
  Write-Host "Failed: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

  foreach ($item in @($skipped + $notRun + $failed)) {
    $detail = if ([string]::IsNullOrWhiteSpace($item.Reason)) {
      $item.ExitCodeHex
    }
    else {
      $item.Reason
    }

    Write-Host "  - $($item.Name): $detail" -ForegroundColor DarkYellow
  }
}


# Main
$configuration = Import-PackageConfiguration -Path $ConfigPath

$requestedProfiles = if ($PSBoundParameters.ContainsKey('Profile')) {
  @($Profile)
}
else {
  @('Default')
}

$resolveParameters = @{
  Configuration     = $configuration
  RequestedProfiles = $requestedProfiles
  Include           = $IncludePackage
  Exclude           = $ExcludePackage
}
$packageKeys = @(Resolve-PackageKeys @resolveParameters)

$planParameters = @{
  Configuration = $configuration
  PackageKey    = $packageKeys
  Proxy         = $Proxy
}
$plan = @(New-InstallationPlan @planParameters)

Show-InstallationPlan -Plan $plan

$wingetPath = $null

$results = @(
  foreach ($item in $plan) {
    if ($item.Action -eq 'Skip') {
      Write-Warning "$($item.Name) was skipped: $($item.Reason)"
      New-InstallResult -PlanItem $item -Status 'Skipped' -ExitCode $null -Duration $null -Reason $item.Reason
      continue
    }

    $target = "$($item.Name) [$($item.Id)], source=$($item.Source), network=$($item.Network)"

    if ($PSCmdlet.ShouldProcess($target, 'Install WinGet package')) {
      if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        $wingetPath = Get-WingetPath
      }

      Install-WingetPlanItem -PlanItem $item -WingetPath $wingetPath
    }
    else {
      $reason = if ($WhatIfPreference) {
        'WhatIf: installation was not executed.'
      }
      else {
        'Installation was declined.'
      }

      New-InstallResult -PlanItem $item -Status 'NotRun' -ExitCode $null -Duration $null -Reason $reason
    }
  }
)

Show-InstallSummary -Results $results

# Emit data through the success stream so callers can filter or export results.
$results

if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) {
  exit 1
}

exit 0
