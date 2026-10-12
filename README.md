# rdms-backup — verified, scheduled mirror of a Mac folder to WebDAV (RUG RDMS)

A small bash tool around [rclone](https://rclone.org) and launchd that keeps a copy of a local folder
(by default `~/Documents`) on a WebDAV server — written for the University of Groningen's Research Data
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
* **Several targets**: a second config file (`backup.sh -c team …`) mirrors selected parts of the tree somewhere else.

## Requirements

macOS, Homebrew: `brew install rclone jq bash` (bash ≥ 4), optionally `terminal-notifier` for nicer notifications.
`python3` (ships with the Xcode command-line tools) is used for Unicode-normalisation of file names.

## Setup

```bash
git clone https://github.com/mf-rug/rdms-backup ~/Documents/Code/backup && cd ~/Documents/Code/backup
cp backup.conf.example backup.conf      # edit: WEBDAV_URL, WEBDAV_USER, REMOTE_PATH, schedule, …
./backup.sh setup            # stores the WebDAV password in the login keychain, tests the connection (at the Mac, not over SSH)
./backup.sh probe            # cheap end-to-end test: list, timing estimate, upload/verify/delete of 3 test files
./backup.sh run --dry-run --full   # what the first run WOULD upload — nothing is written
./backup.sh run --full       # first real run
./backup.sh install          # launchd agent; from now on it runs by itself
```

`status` at any time:

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
| `quota`, `probe`, `diag-keychain` | what the server says about quota; end-to-end test; why the password can't be read |
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

## A second target (e.g. parts of the tree to a team drive)

`backup-team.conf.example` → `backup-team.conf` points at another WebDAV folder and has its own state, logs, agent
(offset wake-up minute) and versions. `FILTER_FILE` (`team-include.txt`, rclone filter rules: `+ /Papers/**` … `- **`)
selects which parts go there; `exclude.txt` and `.nobackup` apply first. Everything works the same with `-c team`.

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
