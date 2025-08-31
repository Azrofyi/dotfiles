<#
.SYNOPSIS
    Установка выбранных приложений через winget
.DESCRIPTION
    Раскомментируй нужные пакеты, остальные будут проигнорированы
#>

#region App List (раскомментируй нужное)

# Формат: "ПакетноеИмя" # Комментарий (для пользователя)
# Найти имена можно командой: winget search <название>

$apps = @(
    "JanDeDobbeleer.OhMyPosh"           # OhMyPosh
    "M2Team.NanaZip"                    # NanaZip
    "FxSound.FxSound"                   # FxSound (Sound equalizer)
    "LibreWolf.LibreWolf"               # LibreWolf
    # "Brave.Brave"                       # Brave
    "qBittorrent.qBittorrent"           # qBittorrent
    "Telegram.TelegramDesktop"          # Telegram
    "Discord.Discord"                   # Discord
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

#region Installation Script

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "❌ Winget не найден! Убедитесь, что установлена App Installer."
    exit 1
}

$installed = @()
$failed = @()

function Install-App {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Id
    )

    Write-Host "📦 Установка: $Id"
    try {
        winget install --id $Id -e --accept-source-agreements --accept-package-agreements --silent --source winget
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            Write-Host "✅ Установлено: $Id"
            $installed += $Id
        }
        else {
            throw "Winget завершился с кодом $exit"
        }
    }
    catch {
        Write-Warning "❌ Ошибка установки $Id`: $($_.Exception.Message)"
        $failed += $Id
    }
}

foreach ($app in $apps) {
    Install-App -Id $app
}

Write-Host "`n📊 Итог установки:"
Write-Host "✅ Успешно установлено: $($installed.Count)"
foreach ($i in $installed) { Write-Host "   + $i" }

if ($failed.Count -gt 0) {
    Write-Host "`n❌ Не удалось установить: $($failed.Count)"
    foreach ($f in $failed) { Write-Host "   - $f" }
}


#endregion
