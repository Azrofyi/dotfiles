#requires -Version 5.1

<#
.SYNOPSIS
    Установка приложений через WinGet.

.DESCRIPTION
    Загружает декларативный список приложений из packages.psd1.

    Поддерживает:
      - логические группы пакетов;
      - источники winget / msstore;
      - установку отдельных пакетов через proxy;
      - интерактивный выбор групп и приложений;
      - стандартные PowerShell -WhatIf и -Confirm;
      - обработку ожидаемых WinGet exit codes.

.EXAMPLE
    .\Install-WinGetPackages.ps1

    Установить группы, помеченные DefaultSelected.

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Core,Optional

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Interactive

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Optional,Trial -Interactive

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Proxy 'http://127.0.0.1:10809'

.EXAMPLE
    .\Install-WinGetPackages.ps1 -SkipProxyPackages

.EXAMPLE
    .\Install-WinGetPackages.ps1 -WhatIf

.EXAMPLE
    .\Install-WinGetPackages.ps1 -Group Optional -Confirm
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string[]]$Group,

  [switch]$Interactive,

  [string]$Proxy,

  [switch]$SkipProxyPackages,

  [ValidateNotNullOrEmpty()]
  [string]$ConfigPath = (
    Join-Path $PSScriptRoot 'packages.psd1'
  )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# В PowerShell 7+ не превращаем non-zero exit codes native-команд
# в PowerShell errors: exit codes winget обрабатываются ниже явно.
$nativeErrorPreference = Get-Variable `
  -Name PSNativeCommandUseErrorActionPreference `
  -ErrorAction SilentlyContinue

if ($null -ne $nativeErrorPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

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

function ConvertTo-PackageDefinition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Package,

    [Parameter(Mandatory)]
    [hashtable]$Defaults
  )

  if (-not $Package.ContainsKey('Id')) {
    throw 'У package отсутствует обязательное поле Id.'
  }

  if (-not $Package.ContainsKey('Group')) {
    throw "У package '$($Package.Id)' отсутствует обязательное поле Group."
  }

  $id = [string]$Package.Id
  $group = [string]$Package.Group

  if ([string]::IsNullOrWhiteSpace($id)) {
    throw 'Обнаружен package с пустым Id.'
  }

  if ([string]::IsNullOrWhiteSpace($group)) {
    throw "У package '$id' поле Group не может быть пустым."
  }

  $name = if (
    $Package.ContainsKey('Name') -and
    -not [string]::IsNullOrWhiteSpace([string]$Package.Name)
  ) {
    [string]$Package.Name
  }
  else {
    $id
  }

  $source = if ($Package.ContainsKey('Source')) {
    [string]$Package.Source
  }
  else {
    [string]$Defaults.Source
  }

  $network = if ($Package.ContainsKey('Network')) {
    [string]$Package.Network
  }
  else {
    [string]$Defaults.Network
  }

  $additionalArgs = if ($Package.ContainsKey('AdditionalArgs')) {
    [string[]]$Package.AdditionalArgs
  }
  else {
    [string[]]@()
  }

  return [pscustomobject]@{
    Id             = $id.Trim()
    Name           = $name.Trim()
    Group          = $group.Trim()
    Source         = $source.Trim()
    Network        = $network.Trim()
    AdditionalArgs = $additionalArgs
  }
}

function Assert-RootConfiguration {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [hashtable]$Config
  )

  foreach ($section in @('Defaults', 'Groups', 'Packages')) {
    if (-not $Config.ContainsKey($section)) {
      throw "В конфигурации отсутствует секция '$section'."
    }
  }

  if ($null -eq $Config.Defaults) {
    throw 'Секция Defaults не может быть пустой.'
  }

  foreach ($property in @('Source', 'Network')) {
    if (-not $Config.Defaults.ContainsKey($property)) {
      throw (
        "В Defaults отсутствует обязательное поле '$property'."
      )
    }

    if (
      [string]::IsNullOrWhiteSpace(
        [string]$Config.Defaults[$property]
      )
    ) {
      throw "Defaults.$property не может быть пустым."
    }
  }

  if ($Config.Defaults.Network -notin @('Direct', 'Proxy')) {
    throw (
      "Defaults.Network содержит неизвестное значение " +
      "'$($Config.Defaults.Network)'. " +
      'Допустимые значения: Direct, Proxy.'
    )
  }
}

function Assert-PackageConfiguration {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Groups,

    [Parameter(Mandatory)]
    [object[]]$Packages
  )

  if ($Groups.Count -eq 0) {
    throw 'В конфигурации не определено ни одной группы.'
  }

  foreach ($group in $Groups) {
    if ([string]::IsNullOrWhiteSpace($group.Name)) {
      throw 'Обнаружена группа с пустым Name.'
    }

    if ([string]::IsNullOrWhiteSpace($group.Title)) {
      throw (
        "У группы '$($group.Name)' отсутствует Title."
      )
    }
  }

  $groupNames = @($Groups.Name)

  $duplicateGroups = @(
    $groupNames |
    Group-Object |
    Where-Object Count -gt 1
  )

  if ($duplicateGroups.Count -gt 0) {
    $names = $duplicateGroups.Name -join ', '

    throw "Обнаружены дублирующиеся группы: $names"
  }

  foreach ($package in $Packages) {
    if ([string]::IsNullOrWhiteSpace($package.Id)) {
      throw 'Обнаружен package с пустым Id.'
    }

    if ([string]::IsNullOrWhiteSpace($package.Group)) {
      throw (
        "У package '$($package.Id)' отсутствует Group."
      )
    }

    if ($package.Group -notin $groupNames) {
      throw (
        "Package '$($package.Id)' ссылается на " +
        "несуществующую группу '$($package.Group)'."
      )
    }

    if ($package.Network -notin @('Direct', 'Proxy')) {
      throw (
        "Package '$($package.Id)' содержит неизвестный " +
        "Network '$($package.Network)'. " +
        'Допустимые значения: Direct, Proxy.'
      )
    }

    if ([string]::IsNullOrWhiteSpace($package.Source)) {
      throw (
        "Package '$($package.Id)' не содержит Source."
      )
    }
  }

  $duplicatePackages = @(
    $Packages |
    Group-Object {
      '{0}:{1}' -f $_.Source, $_.Id
    } |
    Where-Object Count -gt 1
  )

  if ($duplicatePackages.Count -gt 0) {
    $names = $duplicatePackages.Name -join ', '

    throw "Обнаружены дублирующиеся packages: $names"
  }
}

function Assert-RequestedGroups {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Groups,

    [AllowEmptyCollection()]
    [string[]]$RequestedGroups
  )

  if (
    $null -eq $RequestedGroups -or
    $RequestedGroups.Count -eq 0
  ) {
    return
  }

  $knownGroups = @($Groups.Name)

  $unknownGroups = @(
    $RequestedGroups |
    Where-Object {
      $_ -notin $knownGroups
    }
  )

  if ($unknownGroups.Count -eq 0) {
    return
  }

  throw (
    'Неизвестные группы: ' +
    ($unknownGroups -join ', ') +
    '. Доступные группы: ' +
    ($knownGroups -join ', ')
  )
}

function Select-PackageGroups {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [object[]]$Groups,

    [AllowEmptyCollection()]
    [string[]]$RequestedGroups
  )

  if (
    $null -ne $RequestedGroups -and
    $RequestedGroups.Count -gt 0
  ) {
    return @($RequestedGroups)
  }

  return @(
    $Groups |
    Where-Object DefaultSelected |
    ForEach-Object Name
  )
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

  $explicitGroups = (
    $null -ne $RequestedGroups -and
    $RequestedGroups.Count -gt 0
  )

  $groupsToShow = if ($explicitGroups) {
    @(
      $Groups |
      Where-Object {
        $_.Name -in $RequestedGroups
      }
    )
  }
  else {
    @($Groups)
  }

  $selected = @(
    foreach ($group in $groupsToShow) {
      $groupPackages = @(
        $Packages |
        Where-Object Group -eq $group.Name
      )

      if ($groupPackages.Count -eq 0) {
        continue
      }

      Write-Section -Title $group.Title

      foreach ($package in $groupPackages) {
        Write-Host (
          '  - {0} [{1}]' -f (
            $package.Name,
            $package.Id
          )
        ) -ForegroundColor DarkGray
      }

      Write-Host ''

      $choices = @(
        [System.Management.Automation.Host.ChoiceDescription]::new(
          '&Все',
          'Установить все приложения группы.'
        )

        [System.Management.Automation.Host.ChoiceDescription]::new(
          'В&ыборочно',
          'Выбрать приложения по одному.'
        )

        [System.Management.Automation.Host.ChoiceDescription]::new(
          '&Пропустить',
          'Не устанавливать эту группу.'
        )
      )

      $defaultChoice = if (
        $explicitGroups -or
        $group.DefaultSelected
      ) {
        0
      }
      else {
        2
      }

      $choice = $Host.UI.PromptForChoice(
        $group.Title,
        "Пакетов в группе: $($groupPackages.Count)",
        $choices,
        $defaultChoice
      )

      switch ($choice) {
        0 {
          $groupPackages
        }

        1 {
          foreach ($package in $groupPackages) {
            $packageChoices = @(
              [System.Management.Automation.Host.ChoiceDescription]::new(
                '&Да',
                'Установить приложение.'
              )

              [System.Management.Automation.Host.ChoiceDescription]::new(
                '&Нет',
                'Пропустить приложение.'
              )
            )

            $message = '{0} [{1}]' -f (
              $package.Name,
              $package.Id
            )

            $packageChoice = $Host.UI.PromptForChoice(
              'Установить приложение?',
              $message,
              $packageChoices,
              0
            )

            if ($packageChoice -eq 0) {
              $package
            }
          }
        }

        2 {
          continue
        }
      }
    }
  )

  return $selected
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

  if (
    $useProxy -and
    [string]::IsNullOrWhiteSpace($Proxy)
  ) {
    throw (
      "Package '$($Package.Id)' требует proxy, " +
      'но Proxy не указан.'
    )
  }

  $wingetArgs = @(
    'install'
    '--id'
    $Package.Id
    '--source'
    $Package.Source
  )

  # Microsoft Store использует уникальные Store ID,
  # поэтому --exact для msstore не требуется.
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
    '[*] Установка через proxy'
  }
  else {
    '[*] Установка'
  }

  Write-Host (
    '{0}: {1} [{2}]' -f (
      $installLabel,
      $Package.Name,
      $Package.Id
    )
  ) -ForegroundColor Cyan

  $startedAt = Get-Date

  # stdout winget выводим пользователю, но не отдаём
  # в pipeline этой функции.
  & $WingetPath @wingetArgs | Out-Host

  $exitCode = $LASTEXITCODE
  $duration = (Get-Date) - $startedAt
  $formattedCode = Format-ExitCode -ExitCode $exitCode

  if ($exitCode -eq 0) {
    $status = 'Succeeded'

    Write-Host (
      "[OK] $($Package.Name)"
    ) -ForegroundColor Green
  }
  elseif ($exitCode -in $script:WingetNoChangeExitCodes) {
    $status = 'Current'

    Write-Host (
      "[SKIP] Уже установлено или актуально: $($Package.Name)"
    ) -ForegroundColor DarkGreen
  }
  else {
    $status = 'Failed'

    Write-Warning (
      '[FAILED] {0}: {1} ({2})' -f (
        $Package.Name,
        $formattedCode,
        $exitCode
      )
    )
  }

  return [pscustomobject]@{
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

function Show-InstallSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results
  )

  Write-Section -Title 'Итог'

  if ($Results.Count -eq 0) {
    Write-Host (
      'Установка не выполнялась.'
    ) -ForegroundColor Yellow

    return 0
  }

  $succeeded = @(
    $Results |
    Where-Object Status -eq 'Succeeded'
  )

  $current = @(
    $Results |
    Where-Object Status -eq 'Current'
  )

  $failed = @(
    $Results |
    Where-Object Status -eq 'Failed'
  )

  Write-Host (
    "Установлено: $($succeeded.Count)"
  ) -ForegroundColor Green

  foreach ($item in $succeeded) {
    Write-Host (
      '  + {0} [{1}]' -f (
        $item.Name,
        $item.Source
      )
    ) -ForegroundColor DarkGreen
  }

  Write-Host (
    "Уже актуально: $($current.Count)"
  ) -ForegroundColor Green

  foreach ($item in $current) {
    Write-Host (
      '  = {0} [{1}]' -f (
        $item.Name,
        $item.Source
      )
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
    Write-Host (
      '  - {0} [{1}] code={2}' -f (
        $item.Name,
        $item.Source,
        $item.ExitCodeHex
      )
    ) -ForegroundColor DarkRed
  }

  return 1
}

#endregion Helpers

#region Main

$wingetCommandParams = @{
  Name        = 'winget.exe'
  CommandType = 'Application'
  ErrorAction = 'SilentlyContinue'
}

$wingetCommand = Get-Command @wingetCommandParams

if ($null -eq $wingetCommand) {
  throw 'winget.exe не найден.'
}

$wingetPath = $wingetCommand.Source

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Файл конфигурации не найден: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

Assert-RootConfiguration -Config $config

$groups = @(
  foreach ($item in $config.Groups) {
    [pscustomobject]@{
      Name            = [string]$item.Name
      Title           = [string]$item.Title
      DefaultSelected = [bool]$item.DefaultSelected
    }
  }
)

$packages = @(
  foreach ($item in $config.Packages) {
    ConvertTo-PackageDefinition `
      -Package $item `
      -Defaults $config.Defaults
  }
)

Assert-PackageConfiguration `
  -Groups $groups `
  -Packages $packages

$requestedGroups = @(
  $Group |
  Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
  }
)

# Проверяем -Group независимо от режима Interactive.
Assert-RequestedGroups `
  -Groups $groups `
  -RequestedGroups $requestedGroups

if ($SkipProxyPackages) {
  $packages = @(
    $packages |
    Where-Object Network -ne 'Proxy'
  )
}

$selectedPackages = if ($Interactive) {
  $selectionParams = @{
    Groups          = $groups
    Packages        = $packages
    RequestedGroups = $requestedGroups
  }

  @(
    Select-PackagesInteractively @selectionParams
  )
}
else {
  $selectedGroups = @(
    Select-PackageGroups `
      -Groups $groups `
      -RequestedGroups $requestedGroups
  )

  @(
    $packages |
    Where-Object {
      $_.Group -in $selectedGroups
    }
  )
}

if ($selectedPackages.Count -eq 0) {
  $scriptExitCode = Show-InstallSummary -Results @()
  exit $scriptExitCode
}

$requiresProxy = (
  $selectedPackages.Network -contains 'Proxy'
)

$resolvedProxy = $null

if ($requiresProxy -and -not $WhatIfPreference) {
  $resolvedProxy = Resolve-Proxy -CurrentProxy $Proxy

  if ([string]::IsNullOrWhiteSpace($resolvedProxy)) {
    Write-Warning (
      'Proxy не указан. Пакеты с Network=Proxy будут пропущены.'
    )

    $selectedPackages = @(
      $selectedPackages |
      Where-Object Network -ne 'Proxy'
    )
  }
}

$allResults = @(
  foreach ($package in $selectedPackages) {
    $target = '{0} [{1}], source={2}, network={3}' -f (
      $package.Name,
      $package.Id,
      $package.Source,
      $package.Network
    )

    if (
      -not $PSCmdlet.ShouldProcess(
        $target,
        'Установить WinGet package'
      )
    ) {
      continue
    }

    $installParams = @{
      Package    = $package
      WingetPath = $wingetPath
      Proxy      = $resolvedProxy
    }

    Install-WingetPackage @installParams
  }
)

$scriptExitCode = Show-InstallSummary -Results $allResults

exit $scriptExitCode

#endregion Main
