#!/bin/bash
# Double-click me on a Mac: sets up the RDMS backup with a few dialogs (runs "backup.sh wizard" with Homebrew's bash).
cd "$(dirname "$0")" || exit 1
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$b" ] && exec "$b" backup.sh wizard
done
osascript -e 'display dialog "This needs Homebrew and a current bash.\n\nInstall Homebrew from https://brew.sh, then paste into Terminal:\n\nbrew install bash rclone jq\n\nand double-click Setup.command again." with title "RDMS backup" buttons {"OK"} default button "OK"' >/dev/null 2>&1
exit 2
