<#
.SYNOPSIS
    Установка выбранных приложений через winget
.DESCRIPTION
    Раскомментируй нужные пакеты, остальные будут проигнорированы
#>

#region App List (раскомментируй нужное)

$apps = @(
  "JanDeDobbeleer.OhMyPosh"           # OhMyPosh
  "M2Team.NanaZip"                    # NanaZip
  "FxSound.FxSound"                   # FxSound (Sound equalizer)
  "LibreWolf.LibreWolf"               # LibreWolf
  # "Brave.Brave"                       # Brave
  "qBittorrent.qBittorrent"           # qBittorrent
  "Telegram.TelegramDesktop"          # Telegram
  # "Discord.Discord"                   # Discord (Needed proxy)
  "Spotify.Spotify"                   # Spotify
  "Obsidian.Obsidian"                 # Obsidian
  "OBSProject.OBSStudio"              # OBS Studio
  # "VideoLAN.VLC"                      # VLC
  "Microsoft.VisualStudioCode"        # VS Code
  "Neovim.Neovim"                     # NeoVim
  "cURL.cURL"                         # CURL
  "Git.Git"                           # Git
)

#endregion

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Error "[X] Winget не найден!"
  exit 1
}

#region Installation Script

function Install-App {
  <#
    .SYNOPSIS
        Ставит пакет по Id через winget и возвращает объект-результат.
    .OUTPUTS
        [pscustomobject] @{ Id; Status; ExitCode;}
    #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)]
    [string]$Id
  )
  $wingetArgs = @('install', '--id', $Id, '-e', '--accept-source-agreements', '--accept-package-agreements', '--source', 'winget')

  Write-Host "[*] Установка: $Id" -ForegroundColor Cyan

  winget $wingetArgs
  $code = $LASTEXITCODE

  if ($code -eq 0) {
    Write-Host "[OK] Установлено/актуально: $Id" -ForegroundColor Green
    return [pscustomobject]@{
      Id       = $Id
      Status   = 'Installed'
      ExitCode = $code
    }
  }
  else {
    Write-Warning "[!] Ошибка установки $Id (код $code)"
    return [pscustomobject]@{
      Id       = $Id
      Status   = 'Failed'
      ExitCode = $code
    }
  }
}

#endregion

#region Run

$results = @()
$ok = @()
$bad = @()

foreach ($app in $apps) {
  $res = Install-App -Id $app
  if ($res.Status -eq 'Installed') {
    $ok += $res
  } else {
    $bad += $res
  }
  $results += $res
}

#endregion

#region Summary

$okCount = ($ok | Measure-Object).Count
$badCount = ($bad | Measure-Object).Count

Write-Host ""
Write-Host "========== Итог ==========" -ForegroundColor White
Write-Host ("Успешно: {0}" -f $okCount) -ForegroundColor Green
foreach ($i in $ok) { Write-Host ("  + {0}" -f $i.Id) -ForegroundColor DarkGreen }

if ($badCount -gt 0) {
  Write-Host ("Неудачно: {0}" -f $badCount) -ForegroundColor Red
  foreach ($f in $bad) { Write-Host ("  - {0} (код {1})" -f $f.Id, $f.ExitCode) -ForegroundColor DarkRed }
}
else {
  Write-Host "Сбоев нет." -ForegroundColor Green
}

#endregion
