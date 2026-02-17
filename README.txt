╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║              URL WHITELIST PROXY - README                   ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝


QUICK START:
═══════════════════════════════════════════════════════════════

1. Double-click "InstallWatcher.bat" (ONE TIME ONLY)
   → Follow the on-screen instructions
   → Window will close when done
   → Proxy runs automatically after this!
   → For print spool cleanup: right-click InstallWatcher.bat → Run as administrator

2. Configure your browser:
   → Windows Settings → Network & Internet → Proxy
   → Turn ON "Manual proxy setup"
   → Address: 127.0.0.1  Port: 8080
   → Click Save

3. Edit "whitelist.txt" to add allowed websites
   → One website per line (e.g., google.com)
   → Save the file


ADDING WEBSITES:
═══════════════════════════════════════════════════════════════

Open "whitelist.txt" in Notepad and add websites:
  google.com
  youtube.com
  github.com

Save the file - the proxy reloads automatically!


AUTO-START ON LOGIN:
═══════════════════════════════════════════════════════════════

Already configured! The proxy starts automatically on every boot.
No action needed - it runs silently in the background.

PRINT SPOOL CLEANUP (kept printed documents):
═══════════════════════════════════════════════════════════════

If you ran InstallWatcher.bat as Administrator, "kept printed documents"
are cleared automatically:
  • Once about 1 minute after you log on
  • Every day at 03:00 (every 24 hours)

This runs until you use BackToNormal.bat, which removes the cleanup tasks.


STOPPING EVERYTHING (proxy + print spool cleanup):
═══════════════════════════════════════════════════════════════

Run "BackToNormal.bat" to stop the proxy and remove all scheduled tasks
(including the print spool cleanup). Browsing and printing go back to normal.

To stop only the proxy: Task Manager (Ctrl+Shift+Esc) → find "node.exe" → End Task


TROUBLESHOOTING:
═══════════════════════════════════════════════════════════════

Problem: All websites blocked
→ Check whitelist.txt - make sure websites are added correctly

Problem: Proxy not working
→ Check Task Manager to see if node.exe is running
→ If not, double-click "InstallWatcher.bat" again to reinstall
→ Or manually run "StartWatcher.vbs" if needed

Problem: Can't connect
→ Check browser proxy settings (127.0.0.1:8080)


═══════════════════════════════════════════════════════════════
