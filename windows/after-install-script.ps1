<#
.SYNOPSIS
    Скрипты после установки Windows
.DESCRIPTION
    Настройка реестра и обновление компонентов через winget
#>

function Test-Elevation {
    $myIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myPrincipal = [System.Security.Principal.WindowsPrincipal]::new($myIdentity)

    return $myPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevation)) {
    Write-Warning "Скрипт должен быть запущен от имени администратора. Завершение."
    exit 1
}

# Скорость под 1200 dpi
$mouseSpeed = 6
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSensitivity" -Value $mouseSpeed

# Отключаем делей повтора с клавы
Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardDelay" -Value 0

# Отключение ускорения
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value 0
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value 0
Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value 0

# Set UTC Time
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" `
    -Name "RealTimeIsUniversal" -Value 1 -Type DWord

winget update --id Microsoft.WindowsTerminal -e --accept-source-agreements --source winget;
winget update --id Microsoft.AppInstaller -e --source winget;

try {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -ErrorAction Stop
    Write-Host "Hyper-V включён."
} catch {
    Write-Warning "Не удалось включить Hyper-V: $_"
}

Write-Host "Все операции завершены."