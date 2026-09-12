## Unattended Installers with WinGet

`winget` launches the application's installer, so the available options depend on the installer type.

### `--custom`

Adds custom arguments to the default installer arguments used by WinGet:

```powershell
winget install Git.Git --custom '/COMPONENTS=gitlfs,assoc /o:DefaultBranchOption=main'
```

In `AdditionalArgs`, the value of `--custom` must be passed as a **single string**:

```powershell
AdditionalArgs = @(
  '--custom'
  '/COMPONENTS=gitlfs,assoc /o:DefaultBranchOption=main'
)
```

### `--override`

Completely replaces the installer arguments normally provided by WinGet:

```powershell
winget install Git.Git --override "/VERYSILENT /NORESTART ..."
```

Use it when full control over the installer command line is required.

WinGet-level arguments such as `--id`, `--source`, and `--exact` are not replaced. Only the arguments passed to the actual installer are overridden.

### Inno Setup

For example, **Git for Windows**.

Common options:

```text
/VERYSILENT
/NORESTART
/COMPONENTS=...
/SAVEINF=<file>
/LOADINF=<file>
```

Run the GUI installer once and save the selected options:

```powershell
winget download Git.Git --download-directory .\installers
Git-2.xx-64-bit.exe /SAVEINF=C:\git.inf
```

Then use them for unattended installation:

```powershell
winget install Git.Git --override "/VERYSILENT /LOADINF=C:\git.inf"
winget upgrade Git.Git --override "/VERYSILENT /LOADINF=C:\git.inf"
```

Here, `.inf` is an **Inno Setup configuration file**, not a Windows Driver INF.

### Other Installer Types

```text
MSI
  msiexec /i app.msi /qn /norestart

NSIS
  app.exe /S

Inno Setup
  app.exe /VERYSILENT /NORESTART

InstallShield
  setup.exe /s
  setup.exe /s /v"/qn"
```

The exact options depend on the specific installer.

### Choosing an Approach

```text
Minor customization
→ winget --custom

Full control over installer arguments
→ winget --override

Inno Setup with many options
→ /SAVEINF + /LOADINF

MSI
→ msiexec /qn
```

Inspect the package and installer:

```powershell
winget show <PackageId>
winget download <PackageId>

installer.exe /?
installer.exe --help
```
