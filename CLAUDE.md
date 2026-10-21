# rdms-backup — notes for a Claude working in this folder

This is a bash tool that mirrors one folder to the RUG research storage (RDMS) over WebDAV with rclone, on a
schedule, with verification and versioning. README.md explains it; PORTING.md covers the Windows port.

## Setting up a backup for the user ("set up my backup")

Run the commands from this folder (macOS: `./backup.sh …`; Windows Git Bash: `bash backup.sh …`).

1. Ask for two things only: their RUG address (name@rug.nl) and the folder to back up (default: Documents in the
   local profile). Do not ask for the password.
2. `./backup.sh init --user <address> --folder <folder>` writes backup.conf. Read its output: a ⚠ line means the
   folder is inside OneDrive/iCloud/Dropbox; tell the user and ask whether to pick another folder (`init --force`
   to rewrite).
3. `./backup.sh setup --gui` opens a password dialog on the user's screen. Tell the user to type the password into
   that dialog. Allow the tool call at least 10 minutes. You only see "stored: OK / connection test: OK" or a
   failure reason; on failure, check the address and let the user retry.
4. `./backup.sh probe` (end-to-end test, about a minute), then `./backup.sh run --dry-run --full` and summarise
   what would be uploaded (file count, size, anything surprising such as huge caches).
5. `./backup.sh run --full` for the first backup (can take hours; run it in the background or with a long timeout),
   then `./backup.sh install` for the schedule, and `./backup.sh status` to show the result.

Rules: never ask for, read, guess or pass the password in any form (argument, environment variable, file, prompt);
the script refuses such attempts. Do not edit backup.sh or exclude.txt for a setup. backup.conf holds no secrets.
Requirements, if `init` or `probe` complain: macOS `brew install rclone jq bash`; Windows Git for Windows plus
`winget install Rclone.Rclone jqlang.jq Python.Python.3.12`.
