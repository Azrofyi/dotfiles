$useConsoleUi = $Host.Name -eq 'ConsoleHost' -and
-not [Console]::IsInputRedirected -and
-not [Console]::IsOutputRedirected

if ($useConsoleUi) {
  if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons
  }

  # Keep dracula.omp.json next to this profile.
  $themePath = Join-Path $PSScriptRoot 'dracula.omp.json'
  if ((Get-Command oh-my-posh.exe -CommandType Application -ErrorAction SilentlyContinue) -and
    (Test-Path -LiteralPath $themePath -PathType Leaf)) {
    oh-my-posh.exe init pwsh --config $themePath | Invoke-Expression
  }

  if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine

    $readLineOptions = @{
      EditMode                      = 'Windows'
      HistoryNoDuplicates           = $true
      HistorySearchCursorMovesToEnd = $true
      ShowToolTips                  = $true
      PredictionSource              = 'HistoryAndPlugin'
      PredictionViewStyle           = 'ListView'
      BellStyle                     = 'None'
    }
    Set-PSReadLineOption @readLineOptions

    Set-PSReadLineKeyHandler -Chord UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
  }
}

#region Functions

function Get-PathList {
  [CmdletBinding()]
  param()

  $env:Path -split [System.IO.Path]::PathSeparator |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Get-PublicIP {
  [CmdletBinding()]
  param()

  try {
    Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 10 -ErrorAction Stop
  }
  catch {
    Write-Warning "Could not retrieve the public IP address: $($_.Exception.Message)"
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

function Copy-Path {
  param(
    [string]$Path = '.'
  )

  $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  Set-Clipboard -Value $resolvedPath.ProviderPath
}

function Get-ListeningPort {
  param(
    [ValidateRange(1, 65535)]
    [int]$Port
  )

  Get-NetTCPConnection -State Listen |
  Where-Object { -not $Port -or $_.LocalPort -eq $Port } |
  Sort-Object LocalPort |
  Select-Object LocalAddress, LocalPort, OwningProcess, @{
    Name       = 'ProcessName'
    Expression = {
      (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    }
  }
}

function Edit-Hosts {
  $processOptions = @{
    FilePath     = Join-Path $env:SystemRoot 'System32\notepad.exe'
    ArgumentList = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Verb         = 'RunAs'
  }

  Start-Process @processOptions
}

#endregion Functions

#region Aliases

Set-Alias -Name port -Value Get-ListeningPort
Set-Alias -Name cpath -Value Copy-Path
Set-Alias -Name pathl -Value Get-PathList
Set-Alias -Name ll -Value Get-ChildItem

#endregion Aliases
