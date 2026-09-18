# Disable automatic driver delivery and device-associated app downloads

$driverSearching = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
$windowsUpdate = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$deviceMetadata = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'

New-Item -Path $driverSearching -Force | Out-Null
New-Item -Path $windowsUpdate   -Force | Out-Null
New-Item -Path $deviceMetadata  -Force | Out-Null

# Do not search Windows Update for drivers during device installation
New-ItemProperty -Path $driverSearching `
  -Name 'SearchOrderConfig' `
  -PropertyType DWord `
  -Value 0 `
  -Force | Out-Null

# Legacy compatibility: do not search Windows Update if no local driver is found
New-ItemProperty -Path $driverSearching `
  -Name 'DontSearchWindowsUpdate' `
  -PropertyType DWord `
  -Value 1 `
  -Force | Out-Null

# Do not include drivers with Windows Updates
New-ItemProperty -Path $windowsUpdate `
  -Name 'ExcludeWUDriversInQualityUpdate' `
  -PropertyType DWord `
  -Value 1 `
  -Force | Out-Null

# Prevent downloading device metadata / associated applications
New-ItemProperty -Path $deviceMetadata `
  -Name 'PreventDeviceMetadataFromNetwork' `
  -PropertyType DWord `
  -Value 1 `
  -Force | Out-Null
