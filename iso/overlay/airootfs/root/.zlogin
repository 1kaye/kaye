# Auto-start the Kaye OS Live Installer on tty1.
# Exits cleanly back to an interactive root shell on exit or Ctrl+C.
if [[ "$(tty 2>/dev/null)" == "/dev/tty1" && -x /usr/local/bin/kaye-iso-installer ]]; then
  /usr/local/bin/kaye-iso-installer
fi
