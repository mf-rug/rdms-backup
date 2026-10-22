#!/usr/bin/env bash
# tests/local-suite.sh — end-to-end tests of backup.sh against a local dummy target (no server, no password, no
# notifications). Runs on macOS and on Windows (Git Bash). Everything happens in a fresh temp folder; the real
# backup.conf, state and logs are not touched.
#
#   bash tests/local-suite.sh            (keep the temp folder with KEEP=1)
set -uo pipefail
case "$OSTYPE" in msys*|cygwin*) OS=windows ;; *) OS=mac ;; esac
[[ "$OS" == mac ]] && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # bash >= 4, jq, rclone
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$REPO/backup.sh"
T=$(mktemp -d); SRC="$T/src dir"; DST="$T/target"; CONF="$T/test.conf"; STATE="$T/state"; LOGS="$T/logs"
trap '[[ -n "${KEEP:-}" ]] && echo "kept: $T" || rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
bk()   { BACKUP_CONF="$CONF" bash "$SCRIPT" "$@"; }
last() { tail -n 1 "$STATE/runs.jsonl" | jq -r ".$1" | tr -d '\r'; }
nruns() { if [[ -f "$STATE/runs.jsonl" ]]; then grep -c . "$STATE/runs.jsonl"; else echo 0; fi; }
setstate() { jq "$1" "$STATE/state.json" | tr -d '\r' > "$STATE/s.tmp" && mv "$STATE/s.tmp" "$STATE/state.json"; }
latest_log() { cat "$LOGS/latest/run.log"; }

mkdir -p "$SRC/Papers/sub" "$SRC/venv-proj" "$SRC/skipme" "$DST"
printf 'alpha\n' > "$SRC/a.txt"; printf 'paper one\n' > "$SRC/Papers/p1.txt"; printf 'deep\n' > "$SRC/Papers/sub/deep.txt"
printf 'umlaut\n' > "$SRC/Papers/Größe ü & co.txt"
: > "$SRC/venv-proj/pyvenv.cfg"; printf 'x\n' > "$SRC/venv-proj/lib.py"
: > "$SRC/skipme/.nobackup"; printf 'secret\n' > "$SRC/skipme/no.txt"
printf 'junk\n' > "$SRC/.DS_Store"
# all source files older than any run start: split_busy treats files modified within 5 s before a run as "in use"
find "$SRC" -type f -exec touch -t 202501010000 {} +
cat > "$CONF" <<EOF
LOCAL_DIR="$SRC"
REMOTE_OVERRIDE="$DST"
STATE_DIR="$STATE"
LOG_DIR="$LOGS"
EXCLUDE_FILE="$REPO/exclude.txt"
NOTIFY=false
VERSIONS_KEEP_DAYS=30
RUN_HOUR=3; RUN_HOURS=""; RETRY_AFTER_HOURS=0; MAX_RETRIES=2
RCLONE_TRANSFERS=4; RCLONE_CHECKERS=4
LAUNCHD_LABEL="nl.rug.rdms-backup.selftest"
EOF

echo "== static"
check "bash -n backup.sh" bash -n "$SCRIPT"
if command -v shellcheck >/dev/null; then check "shellcheck" shellcheck -s bash "$SCRIPT" "$REPO/tests/local-suite.sh"; else echo "  skip  shellcheck (not installed)"; fi

echo "== 1. first run (full)"
bk run >/dev/null 2>&1
check "result ok"                    [ "$(last result)" = ok ]
check "mode full"                    [ "$(last mode)" = full ]
check "files uploaded"               [ -f "$DST/a.txt" ] && [ -f "$DST/Papers/sub/deep.txt" ]
check "non-ASCII name uploaded"      [ -f "$DST/Papers/Größe ü & co.txt" ]
check "venv skipped (pyvenv.cfg)"    [ ! -e "$DST/venv-proj" ]
check ".nobackup folder skipped"     [ ! -e "$DST/skipme" ]
check "exclude.txt applied"          [ ! -e "$DST/.DS_Store" ]
check "verified"                     [ "$(last verified)" = true ]
check "latest/run.log exists"        [ -f "$LOGS/latest/run.log" ]
FIRST_RUN_DIR=$(last log)

echo "== 2. incremental: same-size edit + new file → versions folder keeps the old copy"
sleep 2
printf 'ALPHA\n' > "$SRC/a.txt"; printf 'new\n' > "$SRC/Papers/new.txt"
bk run >/dev/null 2>&1
check "result ok"                    [ "$(last result)" = ok ]
check "mode incremental"             [ "$(last mode)" = incremental ]
check "edit uploaded"                grep -q ALPHA "$DST/a.txt"
check "new file uploaded"            [ -f "$DST/Papers/new.txt" ]
vfile=$(find "$DST""_versions" -name a.txt 2>/dev/null | head -n 1)
check "old copy in versions folder"  [ -n "$vfile" ] && grep -q alpha "$vfile"
check "previous run dir intact after latest moved" [ -f "$FIRST_RUN_DIR/run.log" ]
check "latest points at the new run" cmp -s "$LOGS/latest/run.log" "$(last log)/run.log"

echo "== 3. corrupted target → run --full detects and repairs"
printf 'corrupted, longer\n' > "$DST/Papers/p1.txt"
touch -t 202001010000 "$DST/Papers/p1.txt"   # older than the local copy, so --update re-uploads … unless the size check must catch it
printf 'xx\n' > "$DST/Papers/sub/deep.txt"; touch -t 203001010000 "$DST/Papers/sub/deep.txt"   # remote "newer": only verification catches it
bk run --full >/dev/null 2>&1
check "result ok"                    [ "$(last result)" = ok ]
check "verification repaired deep.txt" grep -q deep "$DST/Papers/sub/deep.txt"
check "p1.txt restored"              grep -q 'paper one' "$DST/Papers/p1.txt"
check "run.log mentions re-upload"   grep -q 're-uploading' "$(last log)/run.log"

echo "== 4. old version snapshot is pruned"
mkdir -p "$DST""_versions/2020-01-01_0300"; printf 'old\n' > "$DST""_versions/2020-01-01_0300/x.txt"
sleep 1; printf 'ALPHA2\n' > "$SRC/a.txt"
bk run >/dev/null 2>&1
check "result ok"                    [ "$(last result)" = ok ]
check "2020 snapshot removed"        [ ! -e "$DST""_versions/2020-01-01_0300" ]

echo "== 5. check / versions / orphans / status / log"
bk check >/dev/null 2>&1; check "check exits 0 when in sync" [ $? -eq 0 ]
rm "$DST/Papers/new.txt"
bk check >/dev/null 2>&1; check "check exits 1 when a file is missing" [ $? -eq 1 ]
bk run --full >/dev/null 2>&1
out=$(bk versions a.txt 2>&1); check "versions lists a.txt snapshots" grep -q 'a.txt' <<<"$out"
rm "$SRC/Papers/p1.txt"
sleep 1   # run folders are named by start second; the orphans run must sort as the newest
bk orphans >/dev/null 2>&1
check "orphans: deleted file listed" grep -q 'Papers/p1.txt' "$LOGS/latest/orphans-gone.tsv"
out=$(bk status 2>&1); check "status exits 0 and shows last success" grep -q 'last success' <<<"$out"
check "status shows next scheduled slot" grep -qE 'next scheduled: +20[0-9]{2}-' <<<"$out"
out=$(bk log 2>&1); check "log shows the latest run's digest" grep -q 'orphan report' <<<"$out"
out=$(bk log 2 2>&1); check "log 2 shows the run before" grep -q 'result:' <<<"$out"

echo "== 6. tick decisions (state.json manipulated)"
n0=$(nruns)
setstate '.paused = 1 | .last_attempt_epoch = 0'
bk tick >/dev/null 2>&1; check "paused: no run" [ "$(nruns)" = "$n0" ]
setstate '.paused = 0 | .quota_full_epoch = (now|floor)'
bk tick >/dev/null 2>&1; check "remote full <24h: no run" [ "$(nruns)" = "$n0" ]
setstate '.quota_full_epoch = 0'
bk tick >/dev/null 2>&1; check "slot due: run (reason scheduled)" [ "$(last reason)" = scheduled ]
n0=$(nruns)
bk tick >/dev/null 2>&1; check "nothing due: no run" [ "$(nruns)" = "$n0" ]
setstate '.last_result = "fail" | .last_attempt_epoch = (now|floor) - 10 | .retries_since_slot = 0'
bk tick >/dev/null 2>&1; check "after failure: retry" [ "$(last reason)" = retry ]
n0=$(nruns)
setstate '.last_result = "fail" | .last_attempt_epoch = (now|floor) - 10 | .retries_since_slot = 2'
bk tick >/dev/null 2>&1; check "retries exhausted: no run" [ "$(nruns)" = "$n0" ]
setstate '.last_result = "ok"'

echo "== 7. lock: one run at a time"
head -c 400000 /dev/urandom > "$SRC/big.bin"
# deterministic: the lock is held by a live process (independent of how fast a real run is on this disk)
sleep 60 & holder=$!
mkdir -p "$STATE/lock"; echo "$holder" > "$STATE/lock/pid"
n0=$(nruns)
out=$(bk run 2>&1); ec=$?
check "run refused while the lock holder lives (exit 2)" [ "$ec" -eq 2 ]
check "refusal names the running pid" grep -q "already in progress (pid $holder)" <<<"$out"
bk tick >/dev/null 2>&1; ec=$?
check "tick while locked exits 0"    [ "$ec" -eq 0 ]
check "tick while locked does not run" [ "$(nruns)" = "$n0" ]
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -rf "$STATE/lock"
# a real concurrent run (slowed down), when the machine is slow enough to catch it
printf 'RCLONE_EXTRA=(--bwlimit 40k)\n' >> "$CONF"
bk run >/dev/null 2>&1 & bgpid=$!
for _ in $(seq 1 40); do [[ -f "$STATE/lock/pid" ]] && break; sleep 0.25; done
out=$(bk run 2>&1); ec=$?
if kill -0 "$bgpid" 2>/dev/null; then
  check "second real run refused (exit 2)" [ "$ec" -eq 2 ]
else echo "  skip  second real run (the first finished too fast to overlap)"; fi
wait "$bgpid"
sed -i.bak '/--bwlimit/d' "$CONF"
check "slow run finished ok"         [ "$(tail -n 2 "$STATE/runs.jsonl" | jq -r .result | tr -d '\r' | grep -c ok)" -ge 1 ]
check "lock released"                [ ! -e "$STATE/lock" ]
mkdir -p "$STATE/lock"; echo 999999 > "$STATE/lock/pid"
bk run >/dev/null 2>&1
check "stale lock (dead pid) is taken over" [ "$(last result)" = ok ]

echo "== 8. dry run writes nothing"
printf 'dry\n' > "$SRC/dry.txt"
bk run --dry-run >/dev/null 2>&1
check "result dry"                   [ "$(last result)" = dry ]
check "nothing uploaded"             [ ! -e "$DST/dry.txt" ]

if [[ "$OS" == windows ]]; then
  echo "== 9. Windows: a file locked by another program counts as 'in use', not as a failure"
  printf 'locked content\n' > "$SRC/locked.txt"
  printf 'RCLONE_EXTRA=(--retries 1)\n' >> "$CONF"   # no whole-pass retry that would outlast the lock
  lk=$(cygpath -w "$SRC/locked.txt")
  MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -Command "\$f=[IO.File]::Open('$lk','Open','ReadWrite','None'); Start-Sleep 25; \$f.Close()" >/dev/null 2>&1 & lkpid=$!
  sleep 4
  bk run --full >/dev/null 2>&1
  check "result ok despite the lock"  [ "$(last result)" = ok ]
  check "run.log reports the locked file" grep -q 'locked by another program' "$(last log)/run.log"
  check "locked file not uploaded yet" [ ! -e "$DST/locked.txt" ]
  wait "$lkpid"; sed -i.bak '/--retries 1/d' "$CONF"
  bk run --full >/dev/null 2>&1
  check "after release: uploaded"     [ -f "$DST/locked.txt" ] && [ "$(last result)" = ok ]
  check "latest is a junction (not a copy)" [ -L "$LOGS/latest" ]

  echo "== 10. Windows: install / status / uninstall of the scheduled task (label …selftest)"
  bk install >/dev/null 2>&1
  check "task registered"            bash -c "MSYS2_ARG_CONV_EXCL='*' schtasks.exe /Query /TN nl.rug.rdms-backup.selftest >/dev/null 2>&1"
  check "status says registered"     grep -q 'task registered' <<<"$(bk status 2>&1)"
  # shellcheck disable=SC2016   # PowerShell code: $ is PowerShell's
  rep=$(MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -Command '(Get-ScheduledTask -TaskName "nl.rug.rdms-backup.selftest").Triggers | ForEach-Object { "$($_.Repetition.Interval)/$($_.Repetition.Duration)" }' 2>/dev/null | tr -d '\r' | grep PT1H)
  check "hourly repetition has Duration P1D (without it the trigger never fires)" [ "$rep" = "PT1H/P1D" ]
  bk uninstall >/dev/null 2>&1
  check "task removed"               bash -c "! MSYS2_ARG_CONV_EXCL='*' schtasks.exe /Query /TN nl.rug.rdms-backup.selftest >/dev/null 2>&1"
fi

echo "== 11. cloud-synced folder warning (status)"
mkdir -p "$T/OneDrive - Test/docs"; printf 'x\n' > "$T/OneDrive - Test/docs/f.txt"
cat > "$T/cloud.conf" <<EOF
LOCAL_DIR="$T/OneDrive - Test/docs"
REMOTE_OVERRIDE="$T/cloud-target"
STATE_DIR="$T/cloud-state"
LOG_DIR="$T/cloud-logs"
NOTIFY=false
EOF
out=$(BACKUP_CONF="$T/cloud.conf" bash "$SCRIPT" status 2>&1)
check "status warns about a folder inside OneDrive" grep -q 'CLOUD FOLDER' <<<"$out"
out=$(bk status 2>&1)
check "status is silent for a normal folder" test "$(grep -c 'CLOUD FOLDER' <<<"$out")" -eq 0

echo "== 12. init writes a config without prompts; setup refuses passwords passed in"
ic="$T/init.conf"; want=$(cd "$SRC" && pwd -P); [[ "$OS" == windows ]] && want=$(cygpath -m "$want")   # init stores the canonical path
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" init --user "test.user@rug.nl" --folder "$SRC" --hours "4 12" 2>&1); ec=$?
check "init exits 0"                 [ "$ec" -eq 0 ]
check "init prints the summary"      grep -q 'runs at:      4 12h' <<<"$out"
check "LOCAL_DIR written"            grep -qF "LOCAL_DIR=\"$want\"" "$ic"
check "account + URL written"        grep -q '^WEBDAV_USER="test.user@rug.nl"' "$ic"
check "hours: main 4, others 12"     grep -q '^RUN_HOUR=4' "$ic"
check "remote path <host>_Backup/<folder>, spaces replaced" grep -q '^REMOTE_PATH=".*_Backup/src_dir"' "$ic"
check "the rest of the example is kept" grep -q '^VERSIONS_KEEP_DAYS=90' "$ic"
printf 'STATE_DIR="%s"\nLOG_DIR="%s"\nNOTIFY=false\n' "$T/init-state" "$T/init-logs" >> "$ic"
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" status 2>&1); check "generated config loads (status shows the remote)" grep -q '_Backup/src_dir' <<<"$out"
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" init --user "test.user@rug.nl" --folder "$SRC" 2>&1); check "init refuses to overwrite" grep -q 'config exists' <<<"$out"
out=$(BACKUP_CONF="$T/none.conf" bash "$SCRIPT" init --user "someone@gmail.com" --folder "$SRC" 2>&1); check "init rejects a non-RUG address" grep -q 'RUG address' <<<"$out"
out=$(BACKUP_CONF="$T/none.conf" bash "$SCRIPT" init --user "name.@rug.nl" --folder "$SRC" 2>&1); check "init rejects a dot right before the @" grep -q 'RUG address' <<<"$out"
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" setup --password x 2>&1); check "setup refuses --password" grep -q 'never takes a password' <<<"$out"
out=$(RUGBACKUP_PASSWORD=x BACKUP_CONF="$ic" bash "$SCRIPT" setup 2>&1); check "setup refuses a password in the environment" grep -q 'never passed through the environment' <<<"$out"
out=$(BACKUP_CONF="$T/none.conf" bash "$SCRIPT" status 2>&1); check "no config: status says how to create one" grep -q 'Setup.command' <<<"$out"
nc="$T/backup-trial.conf"; BACKUP_CONF="$nc" bash "$SCRIPT" init --user "test.user@rug.nl" --folder "$SRC" --quiet
check "named config (-c trial): own task label"   grep -q '^LAUNCHD_LABEL="nl.rug.rdms-backup.trial"' "$nc"
check "named config: own state and log folders"  grep -q '^STATE_DIR=".*rugbackup-trial' "$nc" && grep -q '^LOG_DIR=".*rugbackup-trial' "$nc"
check "named config: offset tick minute"         grep -q '^TICK_MINUTE=37' "$nc"

echo "== 13. several folders: one config under the common parent with an include list; add a folder later"
M="$T/multi"; mkdir -p "$M/A/sub" "$M/B" "$M/C"; printf 'a\n' > "$M/A/sub/a.txt"; printf 'b\n' > "$M/B/b.txt"; printf 'c\n' > "$M/C/c.txt"; printf 'top\n' > "$M/top.txt"
mc="$T/backup-multi.conf"; rules="$T/backup-multi-folders.txt"
out=$(BACKUP_CONF="$mc" bash "$SCRIPT" init --user "test.user@rug.nl" --folder "$M/A" --folder "$M/B" --folder "$M/A/sub" 2>&1); ec=$?
check "init with several folders exits 0"   [ "$ec" -eq 0 ]
mwant=$(cd "$M" && pwd -P); [[ "$OS" == windows ]] && mwant=$(cygpath -m "$mwant")
check "LOCAL_DIR is the common parent"       grep -qF "LOCAL_DIR=\"$mwant\"" "$mc"
check "include list next to the config"      [ -f "$rules" ] && grep -qx '+ /A/\*\*' "$rules" && grep -qx '+ /B/\*\*' "$rules" && grep -qx -- '- \*' "$rules"
check "nested folder merged into its parent" test "$(grep -c '^+ ' "$rules")" -eq 2
check "name lists the folders"               grep -q '^BACKUP_NAME="A, B backup"' "$mc"
check "config points at the list"            grep -qF "FILTER_FILE=\"$rules\"" "$mc"
mkdir -p "$T/multi-target"
printf 'REMOTE_OVERRIDE="%s"\nSTATE_DIR="%s"\nLOG_DIR="%s"\nNOTIFY=false\n' "$T/multi-target" "$T/multi-state" "$T/multi-logs" >> "$mc"
BACKUP_CONF="$mc" bash "$SCRIPT" run >/dev/null 2>&1
check "run uploads the chosen folders only"  [ -f "$T/multi-target/A/sub/a.txt" ] && [ -f "$T/multi-target/B/b.txt" ] && [ ! -e "$T/multi-target/C" ] && [ ! -e "$T/multi-target/top.txt" ]
out=$(BACKUP_CONF="$mc" bash "$SCRIPT" init --add --folder "$M/C" 2>&1); check "init --add appends a folder" grep -qx '+ /C/\*\*' "$rules"
check "automatic name follows the list"      grep -q '^BACKUP_NAME="A, B, C backup"' "$mc"
out=$(BACKUP_CONF="$mc" bash "$SCRIPT" init --add --folder "$SRC" 2>&1); check "init --add refuses a folder outside the parent" grep -q 'outside' <<<"$out"
BACKUP_CONF="$mc" bash "$SCRIPT" run --full >/dev/null 2>&1
check "full run picks up the added folder"   [ -f "$T/multi-target/C/c.txt" ]
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" init --add --folder "$SRC/Papers" 2>&1); check "init --add refuses on a one-folder config" grep -q 'directly' <<<"$out"

echo "== 14. what the setup window calls: info, plan, cloud-check, setup --test-only, first-run"
jqok() { jq -e "$1" <<<"$2" >/dev/null 2>&1; }   # jqok <filter> <json>
out=$(BACKUP_CONF="$T/none.conf" bash "$SCRIPT" info 2>&1); check "info without a config is JSON" jqok '.config_exists == false and (.missing|type) == "array"' "$out"
out=$(bk info 2>&1); check "info with a config: fields" jqok '.config_exists == true and .several_folders == false and (.hours == [3]) and (.log_dir|length > 0)' "$out"
out=$(BACKUP_CONF="$mc" bash "$SCRIPT" info 2>&1); check "info: several folders flagged" jqok '.several_folders == true' "$out"
out=$(BACKUP_CONF="$T/none.conf" bash "$SCRIPT" plan --folder "$M/A" --folder "$M/B" 2>&1); check "plan returns parent, rules, name" jqok '(.rules|length) == 2 and .name == "A, B backup" and (.folders|length) == 2 and (.remote_path|test("_Backup/multi$"))' "$out"
BACKUP_CONF="$T/none.conf" bash "$SCRIPT" cloud-check "$T/OneDrive - Test/docs" >/dev/null 2>&1; check "cloud-check: inside OneDrive exits 0" [ $? -eq 0 ]
BACKUP_CONF="$T/none.conf" bash "$SCRIPT" cloud-check "$SRC" >/dev/null 2>&1; check "cloud-check: normal folder exits 1" [ $? -eq 1 ]
out=$(bk setup --test-only 2>&1); check "setup --test-only against the local target: OK" grep -q 'connection test: OK' <<<"$out"
out=$(BACKUP_CONF="$ic" bash "$SCRIPT" setup --test-only 2>&1); ec=$?; check "setup --test-only with no password stored: fails, exit 1" [ $ec -eq 1 ] && grep -q 'FAILED' <<<"$out"
out=$(bk first-run 2>&1); check "first-run without a schedule refuses" grep -q 'not installed' <<<"$out"

if [[ "$OS" == windows ]]; then
  echo "== 15. Windows setup window (gui/wizard-win.ps1): parses, ASCII only (PowerShell 5.1 reads a BOM-less .ps1 as ANSI)"
  # shellcheck disable=SC2016   # PowerShell code: $ is PowerShell's
  out=$(WIZ="$(cygpath -w "$REPO/gui/wizard-win.ps1")" MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -Command \
        '$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:WIZ, [ref]$null, [ref]$e); if ($e) { $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } } else { "parse OK" }' 2>&1 | tr -d '\r')
  check "wizard-win.ps1 parses" grep -qx 'parse OK' <<<"$out"
  check "wizard-win.ps1 is ASCII only" bash -c "! LC_ALL=C grep -q '[^[:print:][:space:]]' '$REPO/gui/wizard-win.ps1'"
fi

echo
echo "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
