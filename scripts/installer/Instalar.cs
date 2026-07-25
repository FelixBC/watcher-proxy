// Instalar.exe — the ONE double-click install entry point (carries a professional
// icon in Explorer). It just starts the hidden VBS that launches the WinConfig
// wizard (which self-elevates via UAC). Working dir = the exe's own folder, so the
// relative WatcherBrain\RunWizardHidden.vbs path resolves wherever the bundle is
// extracted.
//
// Instalar.bat (the pre-v1.0.19 plain double-click entry, same behaviour, generic
// icon) used to ship alongside this .exe as its fallback — that left two
// unexplained near-identical files on every machine with nothing telling anyone
// which to use. It is no longer packaged (see build-winconfig-bundle.sh); this
// .exe is now self-contained, so if it can't even start the wizard VBS, it falls
// back to running InstallWatcher.bat directly in a normal visible console — the
// same "never block an install on a UI problem" philosophy WinConfigWizard.ps1's
// own Invoke-ConsoleFallback already uses for a WinForms load failure.
using System;
using System.Diagnostics;
using System.IO;

class Instalar
{
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            string vbs = Path.Combine(dir, "WatcherBrain", "RunWizardHidden.vbs");
            var psi = new ProcessStartInfo("wscript.exe", "\"" + vbs + "\" Install");
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
        catch
        {
            // Could not even launch the hidden wizard VBS (e.g. wscript.exe missing
            // or blocked) - fall back to the plain console installer rather than
            // leaving the user with a double-click that silently does nothing.
            try
            {
                string bat = Path.Combine(dir, "InstallWatcher.bat");
                var psi = new ProcessStartInfo("cmd.exe", "/c \"" + bat + "\"");
                psi.WorkingDirectory = dir;
                psi.UseShellExecute = false;
                Process.Start(psi);
            }
            catch { /* nothing left to fall back to; machine is untouched either way */ }
        }
    }
}
