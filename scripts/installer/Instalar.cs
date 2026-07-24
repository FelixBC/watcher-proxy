// Instalar.exe — a tiny GUI launcher (no console flash) that replaces the plain
// Instalar.bat double-click entry with a real .exe that carries a professional
// icon in Explorer. It just starts the hidden VBS that launches the WinConfig
// wizard (which self-elevates via UAC) — same behaviour as Instalar.bat, so the
// .bat stays as a fallback. Working dir = the exe's own folder, so the relative
// WatcherBrain\RunWizardHidden.vbs path resolves wherever the bundle is extracted.
using System;
using System.Diagnostics;
using System.IO;

class Instalar
{
    static void Main()
    {
        try
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string vbs = Path.Combine(dir, "WatcherBrain", "RunWizardHidden.vbs");
            var psi = new ProcessStartInfo("wscript.exe", "\"" + vbs + "\" Install");
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
        catch { /* fallback: the user can still run Instalar.bat */ }
    }
}
