# rdms-backup — verified, scheduled mirror of a Mac folder to WebDAV (RUG RDMS)

A small bash tool around [rclone](https://rclone.org) and launchd that keeps a copy of a local folder of your
choice (e.g. `~/Documents`, or wherever your work lives; several folders = several configs) on a WebDAV server — written for the University of Groningen's Research Data
Management System (`webdav.data.rug.nl`), usable with any WebDAV share.

What it does beyond `rclone copy`:

* **Upload-only mirror.** Nothing is ever deleted on the server; a folder you `rm -rf` locally is still there.
* **Versions of overwritten files.** Before a remote file is replaced, the old copy is moved server-side into
  `<path>_versions/<run stamp>/…` and kept for a configurable number of days. No extra upload, no local space.
* **Real verification.** After every run `rclone check --one-way --size-only` confirms that each file in scope
  exists on the server with the right size; failures are re-uploaded once and re-checked. Weekly the whole tree.
* **Incremental runs that never walk the remote.** Between full passes only files modified since the last successful
  run are listed locally and looked up remotely — minutes instead of hours.
* **A scheduler that survives reality.** launchd wakes the script hourly; it runs at the configured slots, catches up
  after sleep or downtime, retries after failures, continues a run that hit the time cap, and warns when the backup
  goes stale. One job at a time, with a lock.
* **Feedback you can act on.** macOS notification per successful run (once a day), a dialog on failure, `status`
  with the last success/verification and a table of recent runs, one log folder per run.
* **Credentials in the login keychain**, never on disk. The generated `rclone.conf` contains no secret.
* **Quota awareness** for servers that don't report quota: a tiny write test before each run, and a run that hits
  *507 Insufficient Storage* stops, tells you once, and pauses automatic runs for a day.
* **Any folder, several targets.** `LOCAL_DIR` is whatever you want backed up; a second config file
  (`backup.sh -c <name> …`) backs up another folder, or selected parts of one, to another place.

## Requirements

macOS, Homebrew (Apple Silicon `/opt/homebrew` or Intel `/usr/local`, both fine): `brew install rclone jq bash` (bash ≥ 4;
the scheduler uses whichever bash runs the script), optionally `terminal-notifier` for nicer notifications.
`python3` (ships with the Xcode command-line tools) is used for Unicode-normalisation of file names.
Windows: see [Windows](#windows) below.

Tests: `bash tests/local-suite.sh` runs the whole cycle against a local dummy target (no server, no password).

### Windows

The same script runs under Git Bash ([Git for Windows](https://gitforwindows.org)):
`winget install Git.Git Rclone.Rclone jqlang.jq Python.Python.3.12`. Setup is the same as below (run the commands
in Git Bash; `bash backup.sh …` works too). The Windows-specific parts:

* **Password**: `setup` stores it DPAPI-encrypted in `%LOCALAPPDATA%\rugbackup\state\webdav.cred`. Only the same
  Windows user on the same machine can decrypt it, so a copied state folder needs `setup` again.
  `diag-keychain` tests the decryption.
* **Schedule**: `install` creates a Task Scheduler task named after `LAUNCHD_LABEL`. It wakes the script hourly at `:TICK_MINUTE`
  and at logon, and catches up missed wake-ups. It runs *only while you are logged on*, because the notifications
  need the desktop. Nothing runs while the machine sleeps or nobody is logged in. It starts `bash.exe` through
  `conhost.exe --headless`, so no window appears. Check the task with `schtasks /Query /TN nl.rug.rdms-backup /V /FO LIST`;
  its output goes to `%LOCALAPPDATA%\rugbackup\logs\task.log`. `gui-run` is not needed: it simply runs the command.
* **State and logs**: `%LOCALAPPDATA%\rugbackup\state` and `…\logs`. `logs\latest` is a directory junction.
* **Feedback**: Windows toast notifications; on failure a message box offers to open the log.
* **Locked files**: a file that another program holds open exclusively (e.g. an Outlook .pst) is reported as
  "in use" and picked up by a later run. It does not make the run fail.
* **Paths**: the script turns off Git Bash's automatic path rewriting for native programs (`MSYS2_ARG_CONV_EXCL='*'`)
  and passes all paths to rclone in `C:/…` form. Write paths in the config either way (`$USERPROFILE/Documents`,
  `/c/Users/<you>/…`, `C:/Users/<you>/…`). If you call `backup.sh rclone …` yourself, write local paths as `C:/…`.
* **HOME is not your profile** on managed machines: Git Bash takes HOME from HOMEDRIVE, which can be the network home
  drive (e.g. `X:`). Use `$USERPROFILE/…` in the config (the Windows default for `LOCAL_DIR` is `$USERPROFILE/Documents`),
  and `cd` to the repo by its full path (`cd /c/Users/<you>/rdms-backup`).
* **OneDrive**: if Documents is redirected into OneDrive (Files On-Demand), rclone would download every cloud-only
  file. Back up a genuinely local folder instead. `status` warns when the folder is inside OneDrive and `probe` counts
  the cloud-only files (see *cloud-synced folders* under the limits below).
* Use a machine-specific `REMOTE_PATH` (e.g. `Win_Backup/Documents`) when another machine already backs up with the same account.

## Setup

```bash
git clone https://github.com/mf-rug/rdms-backup ~/rdms-backup && cd ~/rdms-backup     # anywhere you like
cp backup.conf.example backup.conf      # edit: LOCAL_DIR (the folder to back up), WEBDAV_URL, WEBDAV_USER, REMOTE_PATH, schedule, …
./backup.sh setup            # stores the WebDAV password in the login keychain, tests the connection (at the Mac, not over SSH)
./backup.sh probe            # cheap end-to-end test: list, timing estimate, upload/verify/delete of 3 test files
./backup.sh run --dry-run --full   # what the first run WOULD upload — nothing is written
./backup.sh run --full       # first real run
./backup.sh install          # launchd agent; from now on it runs by itself
```

`status` at any time (example with `LOCAL_DIR=~/Documents`):

```
Documents backup   /Users/you/Documents  →  rugdav:Mac_Backup/Documents
  agent:            loaded — wakes hourly at :07, runs after 3h, 11h, 15h, 19h, full run every 7 days at 03h
  last attempt:     2026-10-06 03:11  OK  incremental  4m 23s  5 files / 6.7 MiB
  last success:     2026-10-06 03:11  (5 h ago)
  last full+verify: 2026-10-06 09:59  → next full due 2026-10-13 09:59
  last verify:      2026-10-06 09:59  missing 0, size differs 0
  versions:         overwritten files kept 90 days in rugdav:Mac_Backup/Documents_versions  (backup.sh versions <name>)
  next scheduled:   2026-10-06 11:00 (first hourly wake-up after that; slots at 3h, 11h, 15h, 19h, full pass at 03:00)
```

## Commands

| command | what it does |
|---|---|
| `tick` | launchd entry point (hourly): run if a slot is due, retry after failure, warn if stale |
| `run [--full\|--incremental] [--dry-run]` | back up now |
| `check` | full verification only, nothing uploaded; lists missing / differing files |
| `status`, `log [N]` | health summary with recent runs; digest of the latest (N-th latest) run |
| `versions <name or glob>` | earlier versions of a file kept in the versions folder, with the time each was replaced |
| `orphans` | files on the server that no longer exist locally (or are excluded now), with sizes — pruning candidates |
| `quota`, `probe`, `diag-keychain` | what the server says about quota; end-to-end test of server and local folder; why the password can't be read |
| `setup`, `install`, `uninstall`, `pause`, `resume` | keychain item; launchd agent; stop/continue scheduled runs |
| `gui-run [--wait] <command…>` | run a command inside the GUI login session (needed over SSH: the keychain is locked there) |
| `rclone <args…>` | rclone with the configured remote and credentials, e.g. `rclone lsd rugdav:` — for browsing and restores |
| `-c <name> <command>` | use `backup-<name>.conf` instead of `backup.conf` (a second target) |

## How a run works

1. Read the password from the keychain, write a secret-free `rclone.conf`, check that the server answers, upload and
   delete a tiny write-test file.
2. Pick the mode: **full** (first run, then every `FULL_EVERY_DAYS`, in the `RUN_HOUR` slot) compares the whole tree;
   **incremental** lists local files modified since the last successful run (plus a margin) and only looks those up.
3. `rclone copy --update`: new files and files newer locally than the remote copy are uploaded; the replaced remote copy
   is first moved into the versions folder (`--backup-dir`). Snapshots older than `VERSIONS_KEEP_DAYS` are pruned.
4. `rclone check --one-way --size-only` on the files in scope. Files that fail are re-uploaded once and re-checked.
   Files that were still being written during the run are reported as "in use" rather than as failures.
5. `run.log` (digest), `uploaded.txt`, `errors.txt`, `check-*.txt` in the run folder; `runs.jsonl` and `state.json`
   in the state folder; notification.

Runtime data lives in `~/Library/Application Support/<name>/` (state) and `~/Library/Logs/<name>/` (runs, 90 days).

## What "in sync" means, and the limits

Plain WebDAV servers expose no checksums and don't let clients set modification times, so comparison is by **size and
timestamp**: unchanged = same size and the remote copy is not older than the local file; newer locally → re-uploaded;
older locally with a different size → caught by the verification and re-uploaded; older locally with the same size →
the one blind spot (only happens when you restore an old version over a newer one). Symlinks are skipped, empty folders
are not created, locally deleted files stay on the server (use `orphans` to find them).

File names: macOS stores accented names in NFD; servers and other clients may hold NFC. rclone compares names
normalised, and incremental runs look up both spellings, so both are treated as the same file.

**Cloud-synced folders** (OneDrive, iCloud Drive including "Desktop & Documents", Dropbox, Google Drive): a folder that
a cloud client already syncs gains little from a second copy, and its *online-only* placeholder files would be
downloaded by every run. `status` warns when the backed-up folder lies inside such a location, and `probe` counts the
placeholder files (macOS: dataless files and `.icloud` stubs; Windows: the Files On-Demand attribute). Prefer a folder
that exists only on this computer, or exclude the cloud part.

**File count, not size, is what costs time on the RDMS**: the server commits roughly one small file per second per
connection; 16 parallel transfers give ~80 files/min and more connections don't help. Tens of thousands of tiny files
(virtualenvs, caches, benchmark working directories) are the enemy — `exclude.txt` drops the usual suspects, any folder
with a `pyvenv.cfg` is skipped, and an empty `.nobackup` file excludes any folder. A run stopped by the 10 h cap
(`RCLONE_MAX_RUNTIME`) reports *partial* and is continued at the next retry/slot.

The RDMS does not expose its quota over WebDAV (`quota` returns nothing); the write test and the *507* handling are
the guards. Time Machine cannot use WebDAV as a destination, and a sparse-bundle on this server would be hopeless
(thousands of 8 MB bands rewritten constantly) — hence this tool.

## Restore

```bash
./backup.sh rclone ls   rugdav:Mac_Backup/Documents/Papers                      # browse
./backup.sh rclone copy rugdav:Mac_Backup/Documents/Papers/x.pdf ~/Desktop/      # one file
./backup.sh rclone copy rugdav:Mac_Backup/Documents/Teaching ~/restore/Teaching -P   # a folder, with progress
./backup.sh versions Proposal.docx                                                # earlier versions …
./backup.sh rclone copyto 'rugdav:Mac_Backup/Documents_versions/2026-10-06_0307/Proposals/Proposal.docx' ~/Desktop/Proposal_old.docx
```

## More folders, or a second target (e.g. parts of a folder to a team drive)

Each config file is one backup job: its own `LOCAL_DIR`, destination, state, logs, launchd agent (give each a different
`LAUNCHD_LABEL` and `TICK_MINUTE`) and versions folder; `backup.sh -c <name> …` uses `backup-<name>.conf`. So a second
folder is a second config, and `backup-team.conf.example` shows the other use: the same folder, but only selected parts
(`FILTER_FILE` = `team-include.txt`, rclone filter rules `+ /Papers/**` … `- **`; `exclude.txt` and `.nobackup` apply
first) to another WebDAV location.

## Troubleshooting

* **"Could not read the WebDAV password"** — `diag-keychain` shows exit codes; `setup` at the Mac creates the item with
  an ACL that lets `/usr/bin/security` read it. Over SSH the login keychain is locked: use `gui-run`.
* **Cyberduck's keychain item** for the same server cannot be read by other programs — hence the dedicated item.
* **A run seems stuck** — `status` shows the pid; rclone is stopped after `RCLONE_MAX_RUNTIME`, the next run continues.
* **Server slow to accept the first write** after a long session — the write test waits up to 300 s and retries once.
* **Agent not running** — `launchctl print gui/$(id -u)/<LAUNCHD_LABEL>`, `~/Library/Logs/<name>/launchd.log`, `install` again.
* **Remote full** — `status` says so; `orphans` lists what can go; `rclone delete --files-from-raw <list> <remote>` removes it.

## License

MIT.
