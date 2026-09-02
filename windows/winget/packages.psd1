@{
  <#
  Packages are defined in Catalog and referenced by logical key in Profiles.

  To add a package:
    1. Add a unique entry to Catalog with the required Id.
    2. Add its logical key to one or more Profiles.

  Optional package fields:
    Name           - display name;
    Source         - overrides Defaults.Source;
    Network        - Default or Proxy;
    AdditionalArgs - extra winget arguments as separate array elements.

  Example:
    AdditionalArgs = @('--scope', 'user')

  Do not use arguments already managed by the installer in AdditionalArgs:
    --id, --source, --exact, --proxy, --no-proxy, --silent,
    --disable-interactivity, --accept-source-agreements,
    --accept-package-agreements.

  The proxy address is not stored here. Pass it with -Proxy.
  Profile entries define installation order and must reference Catalog keys.
  Do not rename Defaults, Catalog, Profiles, or their existing properties.
  #>
  Defaults = @{
    Source  = 'winget'
    # Default: do not pass --proxy or --no-proxy; use normal WinGet behavior.
    Network = 'Default'
  }

  # Catalog contains only package identity and installation metadata.
  # Profiles below describe which packages belong to an installation set.
  Catalog  = @{
    PowerShell         = @{
      Id   = 'Microsoft.PowerShell'
      Name = 'PowerShell'
    }

    WindowsTerminal    = @{
      Id   = 'Microsoft.WindowsTerminal'
      Name = 'Windows Terminal'
    }

    OhMyPosh           = @{
      Id   = 'JanDeDobbeleer.OhMyPosh'
      Name = 'Oh My Posh'
    }

    NanaZip            = @{
      Id   = 'M2Team.NanaZip'
      Name = 'NanaZip'
    }

    FxSound            = @{
      Id   = 'FxSound.FxSound'
      Name = 'FxSound'
    }

    LibreWolf          = @{
      Id   = 'LibreWolf.LibreWolf'
      Name = 'LibreWolf'
    }

    Brave              = @{
      Id   = 'Brave.Brave'
      Name = 'Brave'
    }

    QBittorrent        = @{
      Id   = 'qBittorrent.qBittorrent'
      Name = 'qBittorrent'
    }

    Telegram           = @{
      Id   = 'Telegram.TelegramDesktop'
      Name = 'Telegram'
    }

    V2RayN             = @{
      Id   = '2dust.v2rayN'
      Name = 'v2rayN'
    }

    Spotify            = @{
      Id   = 'Spotify.Spotify'
      Name = 'Spotify'
    }

    Obsidian           = @{
      Id   = 'Obsidian.Obsidian'
      Name = 'Obsidian'
    }

    OBSStudio          = @{
      Id   = 'OBSProject.OBSStudio'
      Name = 'OBS Studio'
    }

    VLC                = @{
      Id   = 'VideoLAN.VLC'
      Name = 'VLC'
    }

    VSCode             = @{
      Id   = 'Microsoft.VisualStudioCode'
      Name = 'Visual Studio Code'
    }

    Neovim             = @{
      Id   = 'Neovim.Neovim'
      Name = 'Neovim'
    }

    Curl               = @{
      Id   = 'cURL.cURL'
      Name = 'curl'
    }

    Git                = @{
      Id   = 'Git.Git'
      Name = 'Git'
    }

    DockerDesktop      = @{
      Id   = 'Docker.DockerDesktop'
      Name = 'Docker Desktop'
    }

    FFmpeg             = @{
      Id   = 'Gyan.FFmpeg'
      Name = 'FFmpeg'
    }

    Audacity           = @{
      Id   = 'Audacity.Audacity'
      Name = 'Audacity'
    }

    LocalSend          = @{
      Id   = 'LocalSend.LocalSend'
      Name = 'LocalSend'
    }

    Discord            = @{
      Id      = 'Discord.Discord'
      Name    = 'Discord'
      Network = 'Proxy'
    }

    NvidiaControlPanel = @{
      Id     = '9NF8H0H7WMLT'
      Name   = 'NVIDIA Control Panel'
      Source = 'msstore'
    }

    ChatGPT            = @{
      Id     = '9NT1R1C2HH7J'
      Name   = 'ChatGPT'
      Source = 'msstore'
    }

    DistroAV           = @{
      Id      = 'DistroAV.DistroAV'
      Name    = 'DistroAV'
      Network = 'Proxy'
    }
  }

  # Arrays define installation order. A package may appear in many profiles.
  Profiles = @{
    Default  = @(
      'PowerShell'
      'WindowsTerminal'
      'OhMyPosh'
      'NanaZip'
      'VSCode'
      'Neovim'
      'Curl'
      'Git'
    )

    Optional = @(
      'FFmpeg'
      'Audacity'
      'DockerDesktop'
      'LocalSend'
      'Discord'
      'LibreWolf'
      'Brave'
      'QBittorrent'
      'Telegram'
      'V2RayN'
      'Spotify'
      'Obsidian'
      'OBSStudio'
      'VLC'
      'FxSound'
      'NvidiaControlPanel'
    )

    Trial    = @(
      'DistroAV'
      'ChatGPT'
    )
  }
}
