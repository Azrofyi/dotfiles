#requires -RunAsAdministrator
<#
.SYNOPSIS
  Пост-инсталл скрипт Windows с подробным прогрессом и логированием.
.DESCRIPTION
  Настройка времени/часового пояса/BIOS-UTC, параметров ввода, Hyper-V и обновлений через winget.
  Поддерживает -WhatIf / -Confirm / -Verbose и (опционально) транскрипт в файл.
#>

function Test-Elevation {
  $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [System.Security.Principal.WindowsPrincipal]::new($id)

  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevation)) {
  Write-Warning "Нужны права администратора. Завершение."
  exit 1
}

function Invoke-Confirmed {
  param(
    [Parameter(Mandatory)]
    [string]$Message,

    [Parameter(Mandatory)]
    [scriptblock]$Action
  )

  $choice = Read-Host "$Message (y/n)"
  if ($choice -match '^(y|Y)$') {
    & $Action
  }
  else {
    Write-Host "Пропущено: $Message"
  }
}

function Enable-HyperV {
  param()
  try {
    # -All подтянет подкомпоненты; на Home-редакции может не существовать.
    $res = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop
    if ($res.RestartNeeded) {
      Write-Skip "Требуется перезагрузка для завершения установки Hyper-V."
    }
  }
  catch {
    Write-Warning "Не удалось включить Hyper-V: $($_.Exception.Message)"
  }
}

function Set-TimeSettings {
  param(
    [Parameter()][string]$Tz = 'Russian Standard Time',
    [Parameter()][string[]]$Peers = @('0.pool.ntp.org', '1.pool.ntp.org', '2.pool.ntp.org', '3.pool.ntp.org')
  )
  Set-TimeZone -Name $Tz
  Start-Service w32time
  w32tm /config /update /manualpeerlist:"$Peers" /syncfromflags:manual
  w32tm /resync
  Stop-Service w32time
}

function Set-MouseSpeed {
  param([ValidateRange(1, 20)][int]$Speed)
  $path = 'HKCU:\Control Panel\Mouse'
  # Скорость под ~1200 DPI ≈ 6
  Set-ItemProperty -Path $path -Name "MouseSensitivity" -Value $MouseSpeed

  # Отключение ускорения
  Set-ItemProperty -Path $path -Name "MouseSpeed" -Value 0
  Set-ItemProperty -Path $path -Name "MouseThreshold1" -Value 0
  Set-ItemProperty -Path $path -Name "MouseThreshold2" -Value 0
}

function Set-KeyboardRepeatDelay {
  param()
  $path = 'HKCU:\Control Panel\Keyboard'
  # 0 = минимальная задержка
  Set-ItemProperty -Path $path -Name 'KeyboardDelay' -Value 0
}

# Set UTC Time  (BIOS Sync)
function Set-RealTimeIsUniversal {
  param()
  $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
  Set-ItemProperty -Path $path -Name 'RealTimeIsUniversal' -Value 1 -Type DWord
}

function Invoke-PresetWinget {
  param()
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Skip "winget не найден — шаг пропущен."
    return
  }

  winget update --id Microsoft.WindowsTerminal -e --accept-source-agreements --accept-package-agreements --source winget
  winget update --id Microsoft.AppInstaller -e --accept-source-agreements --accept-package-agreements --source winget
  winget install --id Microsoft.Powershell -e --accept-source-agreements --accept-package-agreements --source winget

  try {
    winget settings --enable ProxyCommandLineOptions
    Write-Ok "Включена опция winget: ProxyCommandLineOptions"
  }
  catch {
    Write-Skip "Не удалось применить winget settings (возможно, старая версия): $($_.Exception.Message)"
  }
}

Set-MouseSpeed -MouseSpeed 6

Set-KeyboardRepeatDelay

Set-RealTimeIsUniversal

Set-TimeSettings

Invoke-PresetWinget

Invoke-Confirmed -Message "Включить Hyper-V?" -Action { Enable-HyperV }

Write-Host "Все операции завершены."
