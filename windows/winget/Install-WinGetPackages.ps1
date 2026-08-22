#requires -Version 5.1

<#
.SYNOPSIS
    Installs applications using WinGet.

.DESCRIPTION
    Loads a declarative application list from packages.psd1.

    Supports:
      - logical package groups;
      - winget / msstore sources;
      - per-package proxy usage;
      - interactive group and package selection;
      - standard PowerShell -WhatIf and -Confirm;
      - handling of expected WinGet exit codes.

.EXAMPLE
    .\Install-WinGetPackages.ps1

    Installs groups marked as DefaultSelected.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Core,Optional

    Installs packages from the Core and Optional groups.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Interactive

    Opens interactive group and package selection.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Optional,Trial -Interactive

    Interactively selects packages from the Optional and Trial groups.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Proxy 'http://127.0.0.1:10809'

    Uses the specified proxy for packages that require it.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -SkipProxyPackages

    Skips packages configured with Network=Proxy.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -WhatIf

    Shows what would be installed without performing installation.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Optional -Confirm

    Installs the Optional group with confirmation prompts.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string[]]$Group,

  [switch]$Interactive,

  [string]$Proxy,

  [switch]$SkipProxyPackages,

  [ValidateNotNullOrEmpty()]
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'packages.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


#region Runtime

# In PowerShell 7+, non-zero exit codes from native commands must not
# be converted into PowerShell errors because WinGet exit codes
# are handled explicitly below.
$nativeErrorPreference = Get-Variable `
  -Name PSNativeCommandUseErrorActionPreference `
  -ErrorAction SilentlyContinue

if ($null -ne $nativeErrorPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

#endregion Runtime


#region Constants

$script:WingetExitCodes = @{
  UpdateNotApplicable = -1978335189 # 0x8A15002B
  AlreadyInstalled    = -1978335135 # 0x8A150061
}

$script:WingetNoChangeExitCodes = @(
  $script:WingetExitCodes.UpdateNotApplicable
  $script:WingetExitCodes.AlreadyInstalled
)

#endregion Constants


#region Output

function Write-Section {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Title
  )

  Write-Host ''
  Write-Host "========== $Title ==========" -ForegroundColor White
}

#endregion Output


#region Configuration

function Get-WingetPath {
  [CmdletBinding()]
  param()

  $command = Get-Command `
    -Name 'winget.exe' `
    -CommandType Application `
    -ErrorAction SilentlyContinue

  if ($null -eq $command) {
    throw 'winget.exe was not found.'
  }

  return $command.Source
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

  $config = Import-PowerShellDataFile -LiteralPath $Path

  foreach ($section in @('Defaults', 'Groups', 'Packages')) {
    if (-not $config.ContainsKey($section)) {
      throw "Configuration section '$section' is missing."
    }
  }


  # --- Defaults ----------------------------------------------------------

  $defaults = $config['Defaults']

  if ($null -eq $defaults) {
    throw 'The Defaults section cannot be empty.'
  }

  foreach ($property in @('Source', 'Network')) {
    if (-not $defaults.ContainsKey($property)) {
      throw "Required property '$property' is missing from Defaults."
    }

    if ([string]::IsNullOrWhiteSpace([string]$defaults[$property])) {
      throw "Defaults.$property cannot be empty."
    }
  }

  $defaultSource = ([string]$defaults['Source']).Trim()
  $defaultNetwork = ([string]$defaults['Network']).Trim()

  if ($defaultNetwork -notin @('Direct', 'Proxy')) {
    throw (
      "Defaults.Network contains an unknown value '$defaultNetwork'. " +
      'Allowed values: Direct, Proxy.'
    )
  }


  # --- Groups ------------------------------------------------------------

  $groups = @(
    foreach ($item in @($config['Groups'])) {
      $name = ([string]$item['Name']).Trim()
      $title = ([string]$item['Title']).Trim()

      if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'A group with an empty Name was found.'
      }

      if ([string]::IsNullOrWhiteSpace($title)) {
        throw "Group '$name' does not have a Title."
      }

      $defaultSelected = if ($item.ContainsKey('DefaultSelected')) {
        [bool]$item['DefaultSelected']
      }
      else {
        $false
      }

      [pscustomobject]@{
        Name            = $name
        Title           = $title
        DefaultSelected = $defaultSelected
      }
    }
  )

  if ($groups.Count -eq 0) {
    throw 'No groups are defined in the configuration.'
  }

  $groupNames = @($groups.Name)

  $duplicateGroups = @(
    $groupNames |
    Group-Object |
    Where-Object Count -gt 1
  )

  if ($duplicateGroups.Count -gt 0) {
    throw "Duplicate groups found: $($duplicateGroups.Name -join ', ')"
  }


  # --- Packages ----------------------------------------------------------

  $packages = @(
    foreach ($item in @($config['Packages'])) {
      $id = ([string]$item['Id']).Trim()
      $groupName = ([string]$item['Group']).Trim()

      if ([string]::IsNullOrWhiteSpace($id)) {
        throw 'A package with an empty Id was found.'
      }

      if ([string]::IsNullOrWhiteSpace($groupName)) {
        throw "Package '$id' has an empty Group."
      }

      if ($groupName -notin $groupNames) {
        throw "Package '$id' references unknown group '$groupName'."
      }

      $name = ([string]$item['Name']).Trim()

      if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $id
      }

      $source = if ($item.ContainsKey('Source')) {
        ([string]$item['Source']).Trim()
      }
      else {
        $defaultSource
      }

      $network = if ($item.ContainsKey('Network')) {
        ([string]$item['Network']).Trim()
      }
      else {
        $defaultNetwork
      }

      $additionalArgs = @()

      if (
        $item.ContainsKey('AdditionalArgs') -and
        $null -ne $item['AdditionalArgs']
      ) {
        $additionalArgs = @(
          [string[]]$item['AdditionalArgs']
        )
      }
      if ([string]::IsNullOrWhiteSpace($source)) {
        throw "Package '$id' does not have a Source."
      }

      if ($network -notin @('Direct', 'Proxy')) {
        throw (
          "Package '$id' contains an unknown Network value '$network'. " +
          'Allowed values: Direct, Proxy.'
        )
      }

      [pscustomobject]@{
        Id             = $id
        Name           = $name
        Group          = $groupName
        Source         = $source
        Network        = $network
        AdditionalArgs = $additionalArgs
      }
    }
  )

  $duplicatePackages = @(
    $packages |
    Group-Object {
      '{0}:{1}' -f $_.Source, $_.Id
    } |
    Where-Object Count -gt 1
  )

  if ($duplicatePackages.Count -gt 0) {
    throw (
      'Duplicate packages found: ' +
      ($duplicatePackages.Name -join ', ')
    )
  }

  return [pscustomobject]@{
    Groups   = $groups
    Packages = $packages
  }
}

#endregion Configuration


#region Selection

function Resolve-RequestedGroups {
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()]
    [string[]]$RequestedGroups,

    [Parameter(Mandatory)]
    [object[]]$AvailableGroups
  )

  $requested = @(
    $RequestedGroups |
    Where-Object {
      -not [string]::IsNullOrWhiteSpace($_)
    } |
    ForEach-Object {
      $_.Trim()
    }
  )

  if ($requested.Count -eq 0) {
    return
  }

  $availableNames = @($AvailableGroups.Name)

  $unknown = @(
    $requested |
    Where-Object {
      $_ -notin $availableNames
    }
  )

  if ($unknown.Count -gt 0) {
    throw (
      'Unknown groups: ' +
      ($unknown -join ', ') +
      '. Available groups: ' +
      ($availableNames -join ', ')
    )
  }

  $requested
}


function Select-Packages {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Groups,

    [Parameter(Mandatory)]
    [object[]]$Packages,

    [AllowEmptyCollection()]
    [string[]]$RequestedGroups
  )

  $selectedGroups = @(
    if ($RequestedGroups.Count -gt 0) {
      $RequestedGroups
    }
    else {
      $Groups |
      Where-Object DefaultSelected |
      ForEach-Object Name
    }
  )

  $Packages |
  Where-Object {
    $_.Group -in $selectedGroups
  }
}


function Select-PackagesInteractively {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Groups,

    [Parameter(Mandatory)]
    [object[]]$Packages,

    [AllowEmptyCollection()]
    [string[]]$RequestedGroups
  )

  $explicitGroups = $RequestedGroups.Count -gt 0

  $groupsToShow = @(
    if ($explicitGroups) {
      $Groups | Where-Object Name -in $RequestedGroups
    }
    else {
      $Groups
    }
  )

  $groupChoices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&All',
      'Install all applications in this group.'
    )
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&Select',
      'Select applications individually.'
    )
    [System.Management.Automation.Host.ChoiceDescription]::new(
      'S&kip',
      'Skip this group.'
    )
  )

  $packageChoices = @(
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&Yes',
      'Install this application.'
    )
    [System.Management.Automation.Host.ChoiceDescription]::new(
      '&No',
      'Skip this application.'
    )
  )

  foreach ($group in $groupsToShow) {
    $groupPackages = @(
      $Packages | Where-Object Group -eq $group.Name
    )

    if ($groupPackages.Count -eq 0) {
      continue
    }

    Write-Section -Title $group.Title

    foreach ($package in $groupPackages) {
      Write-Host "  - $($package.Name) [$($package.Id)]" `
        -ForegroundColor DarkGray
    }

    Write-Host ''

    $defaultChoice = if ($explicitGroups -or $group.DefaultSelected) {
      0
    }
    else {
      2
    }

    $choice = $Host.UI.PromptForChoice(
      $group.Title,
      "Packages in group: $($groupPackages.Count)",
      $groupChoices,
      $defaultChoice
    )

    # Install all
    if ($choice -eq 0) {
      $groupPackages
      continue
    }

    # Skip
    if ($choice -eq 2) {
      continue
    }

    # Select individually
    foreach ($package in $groupPackages) {
      $message = "$($package.Name) [$($package.Id)]"

      $packageChoice = $Host.UI.PromptForChoice(
        'Install application?',
        $message,
        $packageChoices,
        0
      )

      if ($packageChoice -eq 0) {
        $package
      }
    }
  }
}

#endregion Selection


#region Proxy

function Resolve-Proxy {
  [CmdletBinding()]
  param(
    [string]$Proxy
  )

  if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    return $Proxy.Trim()
  }

  $resolvedProxy = Read-Host (
    'Enter HTTP proxy, for example http://127.0.0.1:10809'
  )

  if ([string]::IsNullOrWhiteSpace($resolvedProxy)) {
    return $null
  }

  return $resolvedProxy.Trim()
}

#endregion Proxy


#region WinGet

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


function Install-WingetPackage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object]$Package,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WingetPath,

    [string]$Proxy
  )

  $useProxy = $Package.Network -eq 'Proxy'

  if ($useProxy -and [string]::IsNullOrWhiteSpace($Proxy)) {
    throw "Package '$($Package.Id)' requires a proxy, but Proxy was not specified."
  }

  $wingetArgs = @(
    'install'
    '--id'
    $Package.Id
    '--source'
    $Package.Source
  )

  # Microsoft Store uses unique Store IDs, so --exact is not required here.
  if ($Package.Source -ne 'msstore') {
    $wingetArgs += '--exact'
  }

  $wingetArgs += @(
    '--silent'
    '--disable-interactivity'
    '--accept-source-agreements'
    '--accept-package-agreements'
  )

  if ($useProxy) {
    $wingetArgs += @(
      '--proxy'
      $Proxy
    )
  }

  if ($Package.AdditionalArgs.Count -gt 0) {
    $wingetArgs += $Package.AdditionalArgs
  }

  $installLabel = if ($useProxy) {
    '[*] Installing via proxy'
  }
  else {
    '[*] Installing'
  }

  Write-Host (
    "$installLabel`: $($Package.Name) [$($Package.Id)]"
  ) -ForegroundColor Cyan

  $startedAt = Get-Date

  # Display WinGet stdout to the user without returning it
  # through this function's pipeline.
  & $WingetPath @wingetArgs | Out-Host

  $exitCode = $LASTEXITCODE
  $duration = (Get-Date) - $startedAt
  $formattedCode = Format-ExitCode -ExitCode $exitCode

  if ($exitCode -eq 0) {
    $status = 'Succeeded'
    Write-Host "[OK] $($Package.Name)" -ForegroundColor Green
  }
  elseif ($exitCode -in $script:WingetNoChangeExitCodes) {
    $status = 'Current'

    Write-Host (
      "[SKIP] Already installed or up to date: $($Package.Name)"
    ) -ForegroundColor DarkGreen
  }
  else {
    $status = 'Failed'

    Write-Warning (
      "[FAILED] $($Package.Name): $formattedCode ($exitCode)"
    )
  }

  [pscustomobject]@{
    Id          = $Package.Id
    Name        = $Package.Name
    Group       = $Package.Group
    Source      = $Package.Source
    Network     = $Package.Network
    Status      = $status
    ExitCode    = $exitCode
    ExitCodeHex = $formattedCode
    Duration    = $duration
  }
}

#endregion WinGet


#region Summary

function Show-InstallSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results
  )

  Write-Section -Title 'Summary'

  if ($Results.Count -eq 0) {
    Write-Host 'No installation was performed.' -ForegroundColor Yellow
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

  Write-Host "Installed: $($succeeded.Count)" -ForegroundColor Green

  foreach ($item in $succeeded) {
    Write-Host "  + $($item.Name) [$($item.Source)]" `
      -ForegroundColor DarkGreen
  }

  Write-Host "Already up to date: $($current.Count)" -ForegroundColor Green

  foreach ($item in $current) {
    Write-Host "  = $($item.Name) [$($item.Source)]" `
      -ForegroundColor DarkGreen
  }

  if ($failed.Count -eq 0) {
    Write-Host 'No failures.' -ForegroundColor Green
    return 0
  }

  Write-Host "Failed: $($failed.Count)" -ForegroundColor Red

  foreach ($item in $failed) {
    Write-Host (
      "  - $($item.Name) [$($item.Source)] code=$($item.ExitCodeHex)"
    ) -ForegroundColor DarkRed
  }

  return 1
}

#endregion Summary


#region Main

$wingetPath = Get-WingetPath

$config = Import-PackageConfiguration -Path $ConfigPath

$groups = @($config.Groups)
$packages = @($config.Packages)

$requestedGroups = @(
  Resolve-RequestedGroups `
    -RequestedGroups $Group `
    -AvailableGroups $groups
)


# --- Filtering -------------------------------------------------------------

if ($SkipProxyPackages) {
  $packages = @(
    $packages | Where-Object Network -ne 'Proxy'
  )
}


# --- Selection -------------------------------------------------------------

if ($Interactive) {
  $selectedPackages = @(
    Select-PackagesInteractively `
      -Groups $groups `
      -Packages $packages `
      -RequestedGroups $requestedGroups
  )
}
else {
  $selectedPackages = @(
    Select-Packages `
      -Groups $groups `
      -Packages $packages `
      -RequestedGroups $requestedGroups
  )
}

if ($selectedPackages.Count -eq 0) {
  exit (Show-InstallSummary -Results @())
}


# --- Proxy -----------------------------------------------------------------

$requiresProxy = $selectedPackages.Network -contains 'Proxy'
$resolvedProxy = $null

# Do not prompt for a proxy in -WhatIf mode because no installation
# will actually be performed.
if ($requiresProxy -and -not $WhatIfPreference) {
  $resolvedProxy = Resolve-Proxy -Proxy $Proxy

  if ([string]::IsNullOrWhiteSpace($resolvedProxy)) {
    Write-Warning (
      'Proxy was not specified. Packages with Network=Proxy will be skipped.'
    )

    $selectedPackages = @(
      $selectedPackages | Where-Object Network -ne 'Proxy'
    )
  }
}

if ($selectedPackages.Count -eq 0) {
  exit (Show-InstallSummary -Results @())
}


# --- Installation ----------------------------------------------------------

$allResults = @(
  foreach ($package in $selectedPackages) {
    $target = (
      "$($package.Name) [$($package.Id)], " +
      "source=$($package.Source), network=$($package.Network)"
    )

    if (-not $PSCmdlet.ShouldProcess(
        $target,
        'Install WinGet package'
      )) {
      continue
    }

    Install-WingetPackage `
      -Package $package `
      -WingetPath $wingetPath `
      -Proxy $resolvedProxy
  }
)


# --- Summary ---------------------------------------------------------------

exit (Show-InstallSummary -Results $allResults)

#endregion Main
