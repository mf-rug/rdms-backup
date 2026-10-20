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
printf 'RCLONE_EXTRA=(--bwlimit 40k)\n' >> "$CONF"
bk run >/dev/null 2>&1 & bgpid=$!
for _ in $(seq 1 40); do [[ -f "$STATE/lock/pid" ]] && break; sleep 0.5; done
sleep 2
out=$(bk run 2>&1); ec=$?
check "second run refused (exit 2)"  [ "$ec" -eq 2 ] && grep -q 'already in progress' <<<"$out"
n0=$(nruns)
bk tick >/dev/null 2>&1; ec=$?
check "tick during a run exits 0 without running" [ "$ec" -eq 0 ] && [ "$(nruns)" = "$n0" ]
wait "$bgpid"
sed -i.bak '/--bwlimit/d' "$CONF"
check "slow run finished ok"         [ "$(last result)" = ok ]
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
  bk uninstall >/dev/null 2>&1
  check "task removed"               bash -c "! MSYS2_ARG_CONV_EXCL='*' schtasks.exe /Query /TN nl.rug.rdms-backup.selftest >/dev/null 2>&1"
fi

echo
echo "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
