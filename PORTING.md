# Porting rdms-backup to Windows (Git Bash)

Status: not started. This page is the brief for whoever (or whatever) does it. The target is the **native Windows
build of Claude Code / Git for Windows environment**: `backup.sh` keeps running as bash, with an OS switch for the
handful of places that touch the operating system. The rclone part needs no change at all.

## What already works everywhere

* All rclone calls: `copy --update` with `--backup-dir` versioning, `check --one-way --size-only`, `lsf`-based
  incremental lists, `--files-from-raw`, exclusion rules, `.nobackup` / `pyvenv.cfg` markers.
* The state machine: `state.json` / `runs.jsonl`, lock directory, modes, retries, partial continuation, stale check.
* `exclude.txt`, filter files, the config format, `-c <name>` multi-target.

## The six OS touchpoints

| # | what | macOS now | Windows (Git Bash) |
|---|------|-----------|--------------------|
| 1 | **Scheduler** — `install`, `uninstall`, `gui-run`, `status` ("agent loaded?") | launchd plist in `~/Library/LaunchAgents`, `launchctl bootstrap/bootout/print` | Task Scheduler via `schtasks /Create /SC HOURLY /ST hh:07 /TN <label> /TR "\"C:\Program Files\Git\bin\bash.exe\" -l <script> tick"`, `schtasks /Delete`, `schtasks /Query`. Set "run as soon as possible after a missed start" (`/RL LIMITED`, XML import for the missed-start flag if needed). `gui-run` is unnecessary: there is no locked-keychain problem. |
| 2 | **Password** — `get_password`, `setup`, `diag-keychain` | login keychain via `security` | DPAPI-protected file, user-bound: `setup` prompts and runs `powershell -c "Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content <state>/webdav.cred"`; `get_password` runs `powershell -c "... ConvertTo-SecureString | ... PtrToStringAuto"` to read it back. Only the same Windows user can decrypt it. |
| 3 | **Notifications** — `notify` | `terminal-notifier` / `osascript display notification` + `display dialog` | PowerShell toast (WinRT `ToastNotificationManager`, no module needed) or the BurntToast module if present; dialog via `[System.Windows.Forms.MessageBox]`. Must run in the interactive session: create the task with "run only when user is logged on". |
| 4 | **Dates** — `slot_epoch`, `next_slot_epoch`, `prune_versions`, `fmt_epoch`, run-folder names | BSD `/bin/date -j -f`, `-r`, `-v-1d` | GNU `date` (Git Bash): `date -d "@EPOCH"`, `date -d "YYYY-MM-DD HH:MM:SS" +%s`, `date -d "yesterday"`. Wrap both in `date_parse`/`date_fmt`/`date_shift_days` helpers chosen once by `uname`. |
| 5 | **Small tools** — `stat`, `find`, `timeout`, `nice`, `open`, `hostname -s`, `plutil` | `/usr/bin/stat -f %m`, `/usr/bin/find`, `gtimeout`, `open -a Console` | `stat -c %Y`, `find`, `timeout` (coreutils, present in Git Bash), `nice` exists, `start "" <file>` / `explorer`, `hostname`; `plutil` only matters for plists → not needed. |
| 6 | **Paths & defaults** | `~/Library/Application Support/<name>`, `~/Library/Logs/<name>`, `/opt/homebrew/bin/bash` | `$LOCALAPPDATA/<name>/state` and `/logs` (Git Bash sees them as `/c/Users/<you>/AppData/Local/...`), `BASH_BIN=/usr/bin/bash` (Git Bash). `LOCAL_DIR` as `/c/Users/<you>/Documents` or `C:/Users/<you>/Documents` — test which form rclone.exe accepts from the script. |

Suggested structure: a `case "$(uname -s)" in Darwin) … ;; MINGW*|MSYS*) … ;; esac` block near the top that defines
`os_schedule_install/uninstall/status`, `os_get_password`, `os_store_password`, `os_notify`, `os_dialog`,
`date_*`, `STAT_MTIME`, `TIMEOUT_BIN`, default dirs. The command functions call only those.

## Known traps

* **Git Bash path conversion.** MSYS rewrites arguments that look like POSIX paths before a native `.exe` sees them:
  `/Papers/**` can become `C:/Program Files/Git/Papers/**`. Filter *files* (`--exclude-from`, `--filter-from`,
  `--files-from-raw`) are immune because rclone reads them itself; be careful with anything path-like passed directly
  (`--include`, remote specs starting with `/`). `MSYS_NO_PATHCONV=1` or `MSYS2_ARG_CONV_EXCL="*"` in the environment
  of the rclone call disables the conversion; then pass `LOCAL_DIR` in a form rclone understands (`C:/...`).
* **`python3`** is `python` on Windows (the `python3` alias may open the Microsoft Store). Use `command -v python3 || command -v python`.
* **Line endings**: keep the repo at LF (`.gitattributes` with `* text=auto eol=lf`), or bash chokes on `\r`.
* **OneDrive-redirected Documents** on managed machines: cloud-only placeholders would be pulled down by rclone. Point
  `LOCAL_DIR` at a genuinely local folder or disable Files On-Demand for it.
* **Case-insensitive, NFC filesystem**: nothing to do; the normalisation handling is harmless here.
* **`kill -0 $pid` in the lock**: works for MSYS pids within bash; the lock file is only read by bash.
* **Task Scheduler and sleep**: like launchd it can run a missed task on wake; unlike launchd nothing runs while the user
  is logged out when the task is set to "run only when user is logged on" (needed for toasts). That's acceptable for
  an office machine; document it.

## Test plan (no server needed until the last step)

1. `bash -n backup.sh` and `shellcheck -s bash backup.sh` (shellcheck via `winget install koalaman.shellcheck` or scoop).
2. The local dummy-target suite: a `test.conf` with `REMOTE_OVERRIDE=<local folder>`, `NOTIFY=false`; run `run --full`,
   change a file (same size), add a file → `run` (incremental, versions folder gets the old copy), corrupt a file in the
   target → `run --full` (verification detects + repairs), fake an old snapshot → pruned, `check`, `orphans`, `versions`,
   `status`, `tick` with manipulated `state.json` (due / retry / paused), concurrent `run` → lock refused.
3. `install` → `schtasks /Query /TN <label>` shows the task; a `tick` fired by the task writes to the log; `uninstall`.
4. Notifications: a `run` with `NOTIFY_ON_SUCCESS=true` shows a toast; a forced failure shows the dialog.
5. Against the RDMS with the tester's own account: `setup`, `probe`, `run --dry-run --full`, then a real run into a
   **machine-specific `REMOTE_PATH`** (never the one another machine mirrors into).

## Definition of done

* Same `backup.sh` runs on both platforms from the same repo; `backup.conf.example` documents the Windows paths.
* README gets a "Windows" subsection: Git for Windows, `winget install Rclone.Rclone jqlang.jq Python.Python.3.12`,
  where state/logs live, Task Scheduler notes, the path-conversion caveat.
* The macOS behaviour is unchanged (run the local suite on a Mac too).
