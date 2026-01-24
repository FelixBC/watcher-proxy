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


STOPPING THE PROXY:
═══════════════════════════════════════════════════════════════

Open Task Manager (Ctrl+Shift+Esc)
→ Find "node.exe" or "proxy-server.js" process
→ Right-click and select "End Task"


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
