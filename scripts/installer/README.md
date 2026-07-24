# Instalar.exe — source

`Instalar.exe` (at the repo root, shipped in the bundle) is a tiny GUI launcher that
carries a professional icon in Explorer and just starts the WinConfig install wizard
(same behaviour as `Instalar.bat`, which stays as a fallback).

- `Instalar.cs` — the launcher source (runs `wscript WatcherBrain\RunWizardHidden.vbs Install`).
- `winconfig.ico` — the embedded icon (white gear on the #0f6cbd accent, "WinConfig" disguise).

## Rebuild (on a Windows machine with .NET Framework)

```
csc /nologo /target:winexe /win32icon:winconfig.ico /out:..\..\Instalar.exe Instalar.cs
```

`csc.exe` ships with .NET Framework at
`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. The `winconfig.ico` was
generated with System.Drawing (256px gear); regenerate it there if the look needs to change.

This folder is excluded from the install bundle (see `scripts/build-winconfig-bundle.sh`).
