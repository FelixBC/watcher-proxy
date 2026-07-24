# Instalar.exe — source

`Instalar.exe` (at the repo root, shipped in the bundle) is the ONE double-click
install entry point: a tiny GUI launcher that carries a professional icon in
Explorer and starts the WinConfig install wizard. If it can't even launch the
wizard, it falls back to running `InstallWatcher.bat` directly in a console (see
the fallback block in `Instalar.cs`) — so nothing else needs to ship alongside it.

`Instalar.bat` (repo root) is the pre-v1.0.19 plain double-click entry this .exe
replaced — same behaviour, no custom icon. It is intentionally EXCLUDED from the
packaged bundle now (`scripts/build-winconfig-bundle.sh`): shipping both left two
unexplained near-identical files on every machine with nothing telling anyone
which to use. It stays in git as a manual dev fallback only.

**After editing `Instalar.cs`, rebuild the .exe** (below) — the compiled binary is
committed separately and does not update itself from source changes.

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
