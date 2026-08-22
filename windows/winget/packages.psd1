@{
  Defaults = @{
    Source  = 'winget'
    Network = 'Direct'
  }

  Groups   = @(
    @{
      Name            = 'Core'
      Title           = 'Основные приложения'
      DefaultSelected = $true
    }

    @{
      Name            = 'Optional'
      Title           = 'Дополнительные приложения'
      DefaultSelected = $false
    }

    @{
      Name            = 'Trial'
      Title           = 'Новые / тестируемые приложения'
      DefaultSelected = $false
    }
  )

  Packages = @(
    # ---------------------------------------------------------------------
    # Core
    # ---------------------------------------------------------------------

    @{
      Id    = 'JanDeDobbeleer.OhMyPosh'
      Name  = 'Oh My Posh'
      Group = 'Core'
    }

    @{
      Id    = 'M2Team.NanaZip'
      Name  = 'NanaZip'
      Group = 'Core'
    }

    @{
      Id    = 'FxSound.FxSound'
      Name  = 'FxSound'
      Group = 'Core'
    }

    @{
      Id    = 'LibreWolf.LibreWolf'
      Name  = 'LibreWolf'
      Group = 'Core'
    }

    @{
      Id    = 'Brave.Brave'
      Name  = 'Brave'
      Group = 'Core'
    }

    @{
      Id    = 'qBittorrent.qBittorrent'
      Name  = 'qBittorrent'
      Group = 'Core'
    }

    @{
      Id    = 'Telegram.TelegramDesktop'
      Name  = 'Telegram'
      Group = 'Core'
    }

    @{
      Id    = '2dust.v2rayN'
      Name  = 'v2rayN'
      Group = 'Core'
    }

    @{
      Id    = 'Spotify.Spotify'
      Name  = 'Spotify'
      Group = 'Core'
    }

    @{
      Id    = 'Obsidian.Obsidian'
      Name  = 'Obsidian'
      Group = 'Core'
    }

    @{
      Id    = 'OBSProject.OBSStudio'
      Name  = 'OBS Studio'
      Group = 'Core'
    }

    @{
      Id    = 'VideoLAN.VLC'
      Name  = 'VLC'
      Group = 'Core'
    }

    @{
      Id    = 'Microsoft.VisualStudioCode'
      Name  = 'Visual Studio Code'
      Group = 'Core'
    }

    @{
      Id    = 'Neovim.Neovim'
      Name  = 'Neovim'
      Group = 'Core'
    }

    @{
      Id    = 'cURL.cURL'
      Name  = 'curl'
      Group = 'Core'
    }

    @{
      Id    = 'Git.Git'
      Name  = 'Git'
      Group = 'Core'
    }

    @{
      Id    = 'Docker.DockerDesktop'
      Name  = 'Docker Desktop'
      Group = 'Core'
    }

    @{
      Id    = 'Gyan.FFmpeg'
      Name  = 'FFmpeg'
      Group = 'Core'
    }

    @{
      Id    = 'Audacity.Audacity'
      Name  = 'Audacity'
      Group = 'Core'
    }

    @{
      Id    = 'LocalSend.LocalSend'
      Name  = 'LocalSend'
      Group = 'Core'
    }

    @{
      Id      = 'Discord.Discord'
      Name    = 'Discord'
      Group   = 'Core'
      Network = 'Proxy'
    }

    # ---------------------------------------------------------------------
    # Optional
    # ---------------------------------------------------------------------

    @{
      Id     = '9NF8H0H7WMLT'
      Name   = 'NVIDIA Control Panel'
      Group  = 'Optional'
      Source = 'msstore'
    }

    @{
      Id     = '9NT1R1C2HH7J'
      Name   = 'ChatGPT'
      Group  = 'Optional'
      Source = 'msstore'
    }

    # ---------------------------------------------------------------------
    # Trial
    # ---------------------------------------------------------------------

    @{
      Id      = 'DistroAV.DistroAV'
      Name    = 'DistroAV'
      Group   = 'Trial'
      Network = 'Proxy'
    }
  )
}
