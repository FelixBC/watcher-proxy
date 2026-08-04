// Launcher.cs — the ONE compiled double-click entry point, shipped as TWO named
// copies at the repo/bundle root: Install.exe and Uninstall.exe. Both are built
// from THIS single source (same bytes); each decides its mode from its OWN file
// name at runtime — a name containing "uninstall" runs the uninstall flow, anything
// else installs. This keeps the two launchers guaranteed in lock-step: one source,
// one compile, two renamed copies (see scripts/installer/README.md for the build).
//
// Both carry the WinConfig gear icon in Explorer and are ELEVATED by the embedded
// manifest (Launcher.manifest, requireAdministrator), so UAC prompts on the icon the
// user actually double-clicked ("Install"/"Uninstall") — not on a raw "Windows
// PowerShell" relaunch a beat later — and the wizard it launches shows its window
// immediately with no second prompt. This also keeps the WinConfig disguise intact.
//
// It then starts the "WinConfig" WinForms wizard, trying three ways in order so a
// double-click never silently does nothing:
//   1. PowerShell directly, hidden, with CreateNoWindow - no console flash and NO
//      dependency on Windows Script Host (which some locked-down banca PCs disable).
//   2. wscript -> RunWizardHidden.vbs - the historical no-flash path, in case
//      powershell.exe isn't resolvable but WSH works.
//   3. InstallWatcher.bat / BackToNormal.bat directly in a visible console - last
//      resort, so the double-click does SOMETHING rather than nothing.
// Working dir = the exe's own folder, so the relative paths resolve wherever the
// bundle was extracted. If the wizard's WinForms can't load, the wizard ITSELF also
// falls back to the console script (Invoke-ConsoleFallback), so the fallback is
// layered at both levels.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class Launcher
{
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;

        // Mode is decided by OUR OWN executable name, not a compiled-in constant, so
        // the identical binary works as both Install.exe and Uninstall.exe. Prefer the
        // real module path (survives a rename); fall back to the entry assembly, then
        // to "install" if neither resolves (never crash a double-click over this).
        string self = null;
        try { self = Process.GetCurrentProcess().MainModule.FileName; } catch { }
        if (string.IsNullOrEmpty(self)) { try { self = Assembly.GetEntryAssembly().Location; } catch { } }
        if (string.IsNullOrEmpty(self)) { self = "install"; }
        bool uninstall = Path.GetFileNameWithoutExtension(self).ToLowerInvariant().Contains("uninstall");

        string mode = uninstall ? "Uninstall" : "Install";
        string wizard = Path.Combine(dir, "WatcherBrain", "WinConfigWizard.ps1");
        string vbs = Path.Combine(dir, "WatcherBrain", "RunWizardHidden.vbs");
        string bat = Path.Combine(dir, uninstall ? "BackToNormal.bat" : "InstallWatcher.bat");

        // 1) Preferred: the wizard via PowerShell, no console window, no WSH.
        if (TryStart("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + wizard + "\" -Mode " + mode,
                dir, true))
            return;

        // 2) Fallback: the historical wscript path (no console window either).
        if (TryStart("wscript.exe", "\"" + vbs + "\" " + mode, dir, false))
            return;

        // 3) Last resort: the plain console script, so the double-click does
        //    SOMETHING rather than nothing.
        TryStart("cmd.exe", "/c \"" + bat + "\"", dir, false);
    }

    static bool TryStart(string file, string args, string dir, bool noWindow)
    {
        try
        {
            var psi = new ProcessStartInfo(file, args);
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = noWindow;
            var p = Process.Start(psi);
            return p != null;
        }
        catch
        {
            return false;
        }
    }
}
