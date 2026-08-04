# Install.exe / Uninstall.exe — source

`Install.exe` and `Uninstall.exe` (at the repo root, shipped in the bundle) are the
two double-click entry points: tiny GUI launchers that carry a professional icon in
Explorer and open the WinConfig wizard — install or uninstall. If a launcher can't
even start the wizard, it falls back to running `InstallWatcher.bat` /
`BackToNormal.bat` directly in a console (see the fallback block in `Launcher.cs`) —
so nothing else needs to ship alongside them.

**They are the SAME binary under two names.** Both are compiled from one source
(`Launcher.cs`) and then copied to `Install.exe` and `Uninstall.exe`. Each copy picks
its mode at runtime from its OWN file name — a name containing "uninstall" runs the
uninstall flow, anything else installs — so the two can never drift out of sync.

The old Spanish launchers (`Instalar.exe`, `Instalar.bat`, `Restaurar.bat`) were
replaced by these in the Install/Uninstall rename. On already-installed machines the
OTA only *adds* the new names, so `WatcherBrain/poll-hub.js` (`reconcileLaunchers`,
run once per SYSTEM poll after the update — self-update.js can't do it, since during
its own update the running process is still the OLD code) deletes the obsolete names
and re-hides the new launchers with `+h +s`. The fleet converges on exactly
`Install.exe` + `Uninstall.exe`, both hidden.

**After editing `Launcher.cs` or `Launcher.manifest`, rebuild BOTH exes** (below) —
the compiled binaries are committed separately and do not update themselves from
source changes.

- `Launcher.cs` — the shared launcher source (opens `WatcherBrain\WinConfigWizard.ps1`
  in `-Mode Install`/`-Mode Uninstall`, with wscript→`RunWizardHidden.vbs` and a
  console `.bat` as layered fallbacks).
- `winconfig.ico` — the embedded icon (white gear on the #0f6cbd accent, "WinConfig" disguise).
- `Launcher.manifest` — the embedded application manifest. `requireAdministrator` is
  the point: UAC prompts on "Install"/"Uninstall" (with this icon) instead of on a
  bare PowerShell relaunch, and the wizard then shows with no second prompt.

## Rebuild (on a Windows machine with .NET Framework)

```
csc /nologo /target:winexe /win32icon:winconfig.ico /win32manifest:Launcher.manifest /out:Launcher.exe Launcher.cs
copy /Y Launcher.exe ..\..\Install.exe
copy /Y Launcher.exe ..\..\Uninstall.exe
```

The `/win32manifest:` flag MUST be present — without it the exe is not elevated and
the whole "UAC on the launcher" behaviour is lost. `csc.exe` ships with .NET Framework
at `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. The `winconfig.ico` was
generated with System.Drawing (256px gear); regenerate it there if the look needs to change.

### Rebuild on macOS/Linux (no .NET Framework, dotnet SDK present)

The committed binaries can also be produced with the cross-platform `dotnet` SDK
targeting `net48` (the reference assemblies restore from NuGet):

```
dotnet build -c Release   # a minimal WinExe/net48 .csproj with
                          # <ApplicationManifest>Launcher.manifest</ApplicationManifest>
                          # and <ApplicationIcon>winconfig.ico</ApplicationIcon>
cp bin/Release/net48/<name>.exe ../../Install.exe
cp bin/Release/net48/<name>.exe ../../Uninstall.exe
```

Output is a `net48` PE that runs on the in-box .NET Framework 4.x of every Win10/11
banca — same as the csc build. (A `net8`/modern target would need a runtime the
bancas don't have — always net48.)

CI rebuilds and verifies these exes automatically (`.github/workflows/installer-repro.yml`,
job `build-exe`) — it compiles `Launcher.cs` with `csc`, stamps both names, checks the
`requireAdministrator` string is embedded in each, confirms both are committed at the
repo root, and uploads them as artifacts. It does NOT byte-compare against the
committed copies (Framework `csc` and the Roslyn build used to produce them are not
bit-identical); it proves the source still compiles into a valid elevated PE.

This folder is excluded from the install bundle (see `scripts/build-winconfig-bundle.sh`).
