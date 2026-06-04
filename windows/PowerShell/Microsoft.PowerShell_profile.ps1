# PowerShell profile
# Path example:
# $PROFILE

#region Safety

$script:IsInteractive = $Host.Name -eq 'ConsoleHost'

#endregion Safety

#region Modules and prompt

if ($script:IsInteractive) {
  if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons
  }

  if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $themePath = $null

    if (-not [string]::IsNullOrWhiteSpace($env:POSH_THEMES_PATH)) {
      $themePath = Join-Path $env:POSH_THEMES_PATH 'dracula.omp.json'
    }

    if ($themePath -and (Test-Path $themePath)) {
      oh-my-posh init pwsh --config $themePath | Invoke-Expression
    }
  }
}

#endregion Modules and prompt

#region PSReadLine

if ($script:IsInteractive -and (Get-Module -ListAvailable -Name PSReadLine)) {
  Import-Module PSReadLine

  Set-PSReadLineOption -EditMode Windows
  Set-PSReadLineOption -HistoryNoDuplicates:$true
  Set-PSReadLineOption -ShowToolTips:$true

  # Удобная история/подсказки из истории
  Set-PSReadLineOption -PredictionSource History
  Set-PSReadLineOption -PredictionViewStyle ListView

  # Enter принимает строку только если синтаксис валидный
  Set-PSReadLineKeyHandler -Chord 'Enter' -Function ValidateAndAcceptLine

  # QoL keybindings
  Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -Function DeleteCharOrExit
  Set-PSReadLineKeyHandler -Chord 'Ctrl+w' -Function BackwardKillWord
  Set-PSReadLineKeyHandler -Chord 'Alt+d'  -Function KillWord
  Set-PSReadLineKeyHandler -Chord 'Ctrl+u' -Function BackwardDeleteLine
  Set-PSReadLineKeyHandler -Chord 'Ctrl+k' -Function ForwardDeleteLine
  Set-PSReadLineKeyHandler -Chord 'Ctrl+l' -Function ClearScreen
}

#endregion PSReadLine

#region Functions

function Get-PathList {
  [CmdletBinding()]
  param()

  $env:Path -split [System.IO.Path]::PathSeparator |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Get-CommandPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Name
  )

  Get-Command -Name $Name -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue
}

function Update-WingetPackages {
  [CmdletBinding()]
  param()

  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning 'winget не найден.'
    return
  }

  winget upgrade --all `
    --include-unknown `
    --accept-source-agreements `
    --accept-package-agreements `
    --disable-interactivity `
    --source winget
}

function New-TouchFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Path
  )

  foreach ($item in $Path) {
    if (Test-Path -LiteralPath $item) {
      (Get-Item -LiteralPath $item).LastWriteTime = Get-Date
    }
    else {
      New-Item -ItemType File -Path $item -Force | Out-Null
    }
  }
}

function Edit-Profile {
  [CmdletBinding()]
  param()

  if (Get-Command code -ErrorAction SilentlyContinue) {
    code $PROFILE
    return
  }

  notepad $PROFILE
}

function Reload-Profile {
  [CmdletBinding()]
  param()

  . $PROFILE
}

function Get-PublicIP {
  [CmdletBinding()]
  param()

  try {
    Invoke-RestMethod -Uri 'https://ifconfig.me/ip'
  }
  catch {
    Write-Warning "Не удалось получить public IP: $($_.Exception.Message)"
  }
}

function Get-LocalIP {
  [CmdletBinding()]
  param()

  Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object InterfaceAlias, IPAddress
}

function Test-Port {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$ComputerName,

    [Parameter(Mandatory, Position = 1)]
    [int]$Port
  )

  Test-NetConnection -ComputerName $ComputerName -Port $Port
}

#endregion Functions

#region Aliases

Set-Alias -Name pathl     -Value Get-PathList
Set-Alias -Name which     -Value Get-CommandPath
Set-Alias -Name updateall -Value Update-WingetPackages
Set-Alias -Name touch     -Value New-TouchFile
Set-Alias -Name ep        -Value Edit-Profile
Set-Alias -Name rp        -Value Reload-Profile
Set-Alias -Name ll        -Value Get-ChildItem

#endregion Aliases
