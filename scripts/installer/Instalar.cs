// Instalar.exe - the ONE double-click install entry point (carries the WinConfig
// gear icon in Explorer). It is ELEVATED by its embedded manifest (Instalar.manifest,
// requireAdministrator), so UAC prompts on "Instalar" itself - not on a "Windows
// PowerShell" relaunch a beat later - and the wizard it launches shows its window
// immediately with no second prompt.
//
// It then starts the "WinConfig" WinForms wizard, trying three ways in order so a
// double-click never silently does nothing:
//   1. PowerShell directly, hidden, with CreateNoWindow - no console flash and NO
//      dependency on Windows Script Host (which some locked-down banca PCs disable).
//   2. wscript -> RunWizardHidden.vbs - the historical no-flash path, in case
//      powershell.exe isn't resolvable but WSH works.
//   3. InstallWatcher.bat directly in a visible console - last resort.
// Working dir = the exe's own folder, so the relative paths resolve wherever the
// bundle was extracted. If the wizard's WinForms can't load, the wizard ITSELF also
// falls back to the console installer (Invoke-ConsoleFallback), so the fallback is
// layered at both levels.
using System;
using System.Diagnostics;
using System.IO;

class Instalar
{
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string wizard = Path.Combine(dir, "WatcherBrain", "WinConfigWizard.ps1");
        string vbs = Path.Combine(dir, "WatcherBrain", "RunWizardHidden.vbs");
        string bat = Path.Combine(dir, "InstallWatcher.bat");

        // 1) Preferred: the wizard via PowerShell, no console window, no WSH.
        if (TryStart("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + wizard + "\" -Mode Install",
                dir, true))
            return;

        // 2) Fallback: the historical wscript path (no console window either).
        if (TryStart("wscript.exe", "\"" + vbs + "\" Install", dir, false))
            return;

        // 3) Last resort: the plain console installer, so the double-click does
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
