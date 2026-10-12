#!/opt/homebrew/bin/bash
# backup.sh — scheduled, verified, upload-only mirror of a local folder to WebDAV storage (made for the RUG RDMS) with rclone + launchd.
#
#   backup.sh tick                        launchd entry point (hourly): run if due, warn if stale
#   backup.sh run [--full|--incremental] [--dry-run]
#   backup.sh check                       full verification only (nothing is uploaded)
#   backup.sh status                      health summary + recent runs
#   backup.sh log [N]                     digest of the latest (or N-th latest) run
#   backup.sh setup                       store the WebDAV password in the login keychain
#   backup.sh install | uninstall         create / remove the launchd agent
#   backup.sh pause | resume              stop / restart scheduled runs (agent stays loaded)
#   backup.sh retire-old [--yes]          unload the old duck agents + cron line, moving them into old/
#   backup.sh versions <name or pattern>  earlier versions of a file kept in the _versions folder (overwritten files)
#   backup.sh orphans                     what is on the remote but not local any more (pruning candidates, with sizes)
#   backup.sh quota                       storage quota as reported by the server (if it reports one)
#   backup.sh probe                       cheap end-to-end test of the server (list, time, upload, verify, delete)
#   backup.sh gui-run [--wait] <cmd…>     run any command inside the GUI login session (keychain is unlocked there;
#                                         needed when working over SSH), e.g.  backup.sh gui-run --wait probe
#   backup.sh rclone <args…>              rclone with the configured remote + credentials, e.g. `rclone lsd rugdav:`
#
# Settings live in backup.conf next to this script. A second target is a second config: backup-<name>.conf,
# addressed with  backup.sh -c <name> <command>  (or BACKUP_CONF=/path/to/conf). Each config has its own state,
# logs and launchd agent; FILTER_FILE selects which parts of LOCAL_DIR it covers.
# Runtime data: state.json, runs.jsonl and rclone.conf in STATE_DIR; one folder per run in LOG_DIR.
#
# How a run works
#   1. read the password from the login keychain, write a secret-free rclone.conf, check the remote answers
#   2. pick the mode: "full" (whole tree; first run and every FULL_EVERY_DAYS) or "incremental"
#      (only files modified since the last successful run, listed locally, then looked up remotely)
#   3. rclone copy  — upload-only mirror, never deletes on the remote. With COMPARE_MODE=update a file is
#      re-uploaded when it is newer locally than the remote copy (catches edits that keep the size). The remote copy
#      it replaces is first moved (server-side) into <REMOTE_PATH>_versions/<run stamp>/ and kept VERSIONS_KEEP_DAYS.
#   4. rclone check --one-way --size-only — independent verification: every local file in scope exists
#      remotely with the same size. Files that fail are re-uploaded once and re-checked.
#   5. record the run (runs.jsonl, state.json), write the digest (run.log), notify.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

(( BASH_VERSINFO[0] >= 4 )) || { echo "backup.sh needs bash >= 4 (brew install bash)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
if [[ "${1:-}" == "-c" && -n "${2:-}" ]]; then BACKUP_CONF="$SCRIPT_DIR/backup-$2.conf"; shift 2; fi   # backup.sh -c team …
CONF="${BACKUP_CONF:-$SCRIPT_DIR/backup.conf}"

# ----------------------------------------------------------------------------- defaults (see backup.conf)
BACKUP_NAME="Documents backup"           # shown in notifications and status
LOCAL_DIR="$HOME/Documents"
FILTER_FILE=""                           # optional rclone --filter-from file: which parts of LOCAL_DIR this target covers
WEBDAV_URL=""; WEBDAV_USER=""; WEBDAV_VENDOR="other"
REMOTE_NAME="rugdav"; REMOTE_PATH=""
REMOTE_OVERRIDE=""                       # tests: any rclone remote or local path; bypasses WebDAV + keychain
KEYCHAIN_SERVICE="rugbackup"; KEYCHAIN_FALLBACK_SERVER=""
EXCLUDE_FILE="$SCRIPT_DIR/exclude.txt"; NOBACKUP_MARKER=".nobackup"; VENV_MARKER="pyvenv.cfg"
STATE_DIR="$HOME/Library/Application Support/rugbackup"
LOG_DIR="$HOME/Library/Logs/rugbackup"; LOG_KEEP_DAYS=90
RUN_HOUR=3; RUN_HOURS=""; FULL_EVERY_DAYS=7; RETRY_AFTER_HOURS=3; MAX_RETRIES=2
VERSIONS_KEEP_DAYS=0; VERSIONS_PATH=""
STALE_AFTER_HOURS=48; INCREMENTAL_MAX_FILES=50000
NOTIFY=true; NOTIFY_ON_SUCCESS=true; FAILURE_DIALOG=true
RCLONE_TRANSFERS=4; RCLONE_CHECKERS=8; RCLONE_MAX_RUNTIME="10h"; COMPARE_MODE="update"
RCLONE_EXTRA=()
LAUNCHD_LABEL="nl.rug.rdms-backup"; TICK_MINUTE=7; BASH_BIN="/opt/homebrew/bin/bash"

[[ -f "$CONF" ]] || { echo "config not found: $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONF"

REMOTE="${REMOTE_OVERRIDE:-$REMOTE_NAME:$REMOTE_PATH}"
[[ -n "$VERSIONS_PATH" ]] || VERSIONS_PATH="${REMOTE_PATH}_versions"
if [[ -n "$REMOTE_OVERRIDE" ]]; then VERSIONS_REMOTE="${REMOTE_OVERRIDE%/}_versions"; else VERSIONS_REMOTE="$REMOTE_NAME:$VERSIONS_PATH"; fi
if [[ "$REMOTE" == *:* ]]; then REMOTE_ROOT="${REMOTE%%:*}:"; else REMOTE_ROOT="$REMOTE"; fi
STATE_FILE="$STATE_DIR/state.json"; RUNS_FILE="$STATE_DIR/runs.jsonl"
LOCK_DIR="$STATE_DIR/lock"; RCLONE_CONF="$STATE_DIR/rclone.conf"
KEYCHAIN_HINT="Could not read the WebDAV password from the login keychain (item '$KEYCHAIN_SERVICE', account '$WEBDAV_USER'). Create it once by running 'backup.sh setup' in a Terminal on the Mac itself (over SSH the keychain is locked). 'backup.sh diag-keychain' shows details."

FILTER_ARGS=(--skip-links)
[[ -f "$EXCLUDE_FILE" ]] && FILTER_ARGS+=(--exclude-from "$EXCLUDE_FILE")
if [[ -n "$FILTER_FILE" ]]; then [[ -f "$FILTER_FILE" ]] || { echo "FILTER_FILE not found: $FILTER_FILE" >&2; exit 2; }; FILTER_ARGS+=(--filter-from "$FILTER_FILE"); fi
[[ -n "$NOBACKUP_MARKER" ]] && FILTER_ARGS+=(--exclude-if-present "$NOBACKUP_MARKER")
[[ -n "$VENV_MARKER" ]] && FILTER_ARGS+=(--exclude-if-present "$VENV_MARKER")
RC_NET=(--retries 3 --low-level-retries 10 --retries-sleep 30s --timeout 5m --contimeout 60s)
RC_LOG=(--use-json-log --log-level INFO --stats 5m --stats-log-level NOTICE)

# ----------------------------------------------------------------------------- helpers
die()  { echo "ERROR: $*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
now()  { /bin/date +%s; }
iso()  { /bin/date "+%Y-%m-%dT%H:%M:%S%z"; }
ts()   { /bin/date "+%Y-%m-%d %H:%M:%S"; }
fmt_epoch() { if [[ "${1:-0}" =~ ^[0-9]+$ ]] && (( $1 > 0 )); then /bin/date -r "$1" "+%Y-%m-%d %H:%M"; else echo never; fi; }
fmt_ago()   { local s=$(( $(now) - $1 )); if (( s < 3600 )); then echo "$((s/60)) min ago"; elif (( s < 172800 )); then echo "$((s/3600)) h ago"; else echo "$((s/86400)) days ago"; fi; }
fmt_dur()   { local s=${1:-0}; if (( s < 60 )); then echo "${s}s"; elif (( s < 3600 )); then echo "$((s/60))m $((s%60))s"; else echo "$((s/3600))h $(((s%3600)/60))m"; fi; }
fmt_bytes() { awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }
count_lines() { if [[ -f "$1" ]]; then grep -c . "$1" || true; else echo 0; fi; }
tmo()     { if have gtimeout; then gtimeout "$@"; else shift; "$@"; fi; }       # tmo <duration> <cmd…>
osa_esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
xml_esc() { local s=${1//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
require() { local c; for c in "$@"; do have "$c" || die "missing dependency: $c (brew install $c)"; done; }
usage()   { sed -n '2,21p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; }

RUN_DIR=""; RUN_LOG=""
log() {
  local line; line="$(ts)  $*"
  [[ -n "$RUN_LOG" ]] && printf '%s\n' "$line" >> "$RUN_LOG"
  if [[ -t 1 || -n "${VERBOSE:-}" ]]; then printf '%s\n' "$line"; fi
  return 0
}

# ----------------------------------------------------------------------------- state (state.json via jq)
state_init() { mkdir -p "$STATE_DIR" "$LOG_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null; [[ -s "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"; }
state_get()  { jq -r --arg k "$1" --arg d "${2:-}" 'if has($k) and .[$k] != null then .[$k] else $d end' "$STATE_FILE"; }
state_set() {   # state_set key value [key value …]  (numeric strings are stored as numbers)
  local filter="." i=0 tmp="$STATE_FILE.tmp"; local -a args=()
  while (( $# >= 2 )); do
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    filter+=" | .[\$k$i] = (\$v$i | (tonumber? // .))"
    shift 2; i=$((i+1))
  done
  jq "${args[@]}" "$filter" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ----------------------------------------------------------------------------- lock (one run at a time)
LOCK_HELD=0
lock_pid()     { cat "$LOCK_DIR/pid" 2>/dev/null; }
lock_running() { local p; p=$(lock_pid); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }
lock_acquire() {
  mkdir -p "$STATE_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_running && return 1
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null || return 1      # stale lock from a dead run
  fi
  echo $$ > "$LOCK_DIR/pid"; LOCK_HELD=1
}
lock_release() { (( LOCK_HELD )) && rm -rf "$LOCK_DIR"; LOCK_HELD=0; }
RCLONE_PID=""
on_signal() { log "interrupted by signal — stopping rclone"; [[ -n "$RCLONE_PID" ]] && kill "$RCLONE_PID" 2>/dev/null; lock_release; exit 143; }

# ----------------------------------------------------------------------------- credentials + rclone
get_password() {
  local pw
  if [[ -n "$KEYCHAIN_SERVICE" ]] && pw=$(tmo 45 security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$WEBDAV_USER" -w 2>/dev/null) && [[ -n "$pw" ]]; then printf '%s' "$pw"; return 0; fi
  if [[ -n "$KEYCHAIN_FALLBACK_SERVER" ]] && pw=$(tmo 45 security find-internet-password -s "$KEYCHAIN_FALLBACK_SERVER" -a "$WEBDAV_USER" -w 2>/dev/null) && [[ -n "$pw" ]]; then printf '%s' "$pw"; return 0; fi
  return 1
}
setup_rclone() {   # writes a secret-free rclone.conf; the password travels in the environment only
  mkdir -p "$STATE_DIR"; ( umask 077; : > "$RCLONE_CONF" )
  [[ -n "$REMOTE_OVERRIDE" ]] && return 0
  [[ -n "$WEBDAV_URL" && -n "$WEBDAV_USER" && -n "$REMOTE_PATH" ]] || die "WEBDAV_URL, WEBDAV_USER and REMOTE_PATH must be set in $CONF"
  printf '[%s]\ntype = webdav\nurl = %s\nvendor = %s\nuser = %s\n' "$REMOTE_NAME" "$WEBDAV_URL" "$WEBDAV_VENDOR" "$WEBDAV_USER" > "$RCLONE_CONF"
  local pw; pw=$(get_password) || return 1
  local var="RCLONE_CONFIG_${REMOTE_NAME^^}_PASS"
  export "$var=$(printf '%s' "$pw" | rclone obscure -)"
  unset pw
}
rc() { rclone --config "$RCLONE_CONF" "$@"; }
run_rclone() {   # run_rclone <rclone args…>  → rclone's exit code (124 = RCLONE_MAX_RUNTIME hit)
  local -a cmd=(rclone --config "$RCLONE_CONF" "$@")
  [[ -n "$RCLONE_MAX_RUNTIME" ]] && have gtimeout && cmd=(gtimeout -k 60 "$RCLONE_MAX_RUNTIME" "${cmd[@]}")
  nice -n 10 "${cmd[@]}" </dev/null >>"$RUN_DIR/rclone-stderr.txt" 2>&1 &
  RCLONE_PID=$!
  wait "$RCLONE_PID"; local ec=$?; RCLONE_PID=""
  return $ec
}
rclone_exit_msg() {
  case $1 in
    0) echo ok;; 1) echo "rclone: usage error";; 2) echo "rclone: error";; 3) echo "rclone: directory not found";;
    4) echo "rclone: file not found";; 5) echo "rclone: temporary error, retries exhausted";;
    6) echo "rclone: some files failed";; 7) echo "rclone: fatal error";; 8) echo "rclone: transfer limit exceeded";;
    10) echo "rclone: duration limit reached";; 124|137) echo "rclone: stopped after RCLONE_MAX_RUNTIME=$RCLONE_MAX_RUNTIME";;
    *) echo "rclone: exit code $1";;
  esac
}

# ----------------------------------------------------------------------------- run steps
ST_TRANSFERS=0; ST_BYTES=0; ST_CHECKS=0; ST_ERRORS=0
parse_stats() {   # parse_stats <rclone jsonl> → ST_*
  local s; s=$(jq -Rc 'fromjson? | select(.stats) | .stats' "$1" 2>/dev/null | tail -n 1); [[ -n "$s" ]] || s='{}'
  read -r ST_TRANSFERS ST_BYTES ST_CHECKS ST_ERRORS < <(jq -r '[(.transfers//0),(.bytes//0),(.checks//0),(.errors//0)] | map(floor) | @tsv' <<<"$s" | tr '\t' ' ')
}
digest_copy() {   # digest_copy <rclone jsonl> <dry 0/1> → uploaded.txt / would-upload.txt, errors.txt, lines in run.log
  local f=$1 dry=$2 list n label
  if (( dry )); then list="$RUN_DIR/would-upload.txt"; label="would upload"
    jq -Rr 'fromjson? | select(.object != null and (.msg|startswith("Skipped copy"))) | .object' "$f" > "$list"
  else list="$RUN_DIR/uploaded.txt"; label="uploaded"
    jq -Rr 'fromjson? | select(.object != null and (.msg|startswith("Copied"))) | .object' "$f" > "$list"
  fi
  jq -Rr 'fromjson? | select(.level=="error") | "\(.object // "-"): \(.msg)"' "$f" >> "$RUN_DIR/errors.txt"
  n=$(count_lines "$list")
  if (( n > 0 )); then log "$label ($n):"; head -n 100 "$list" | sed 's/^/    /' >> "$RUN_LOG"; (( n > 100 )) && log "    … and $((n-100)) more, see $(basename "$list")"; fi
  n=$(count_lines "$RUN_DIR/errors.txt")
  if (( n > 0 )); then log "errors ($n):"; head -n 50 "$RUN_DIR/errors.txt" | sed 's/^/    /' >> "$RUN_LOG"; (( n > 50 )) && log "    … and $((n-50)) more, see errors.txt"; fi
}

WIN_COUNT=0
make_window_list() {   # make_window_list <hours> → window-files.txt (local names + NFC/NFD spellings), WIN_COUNT
  rc lsf "$LOCAL_DIR" -R --files-only --max-age "${1}h" "${FILTER_ARGS[@]}" > "$RUN_DIR/window-local.txt" 2>>"$RUN_DIR/rclone-stderr.txt" || return 1
  WIN_COUNT=$(count_lines "$RUN_DIR/window-local.txt")
  python3 - "$RUN_DIR/window-local.txt" > "$RUN_DIR/window-files.txt" <<'PY'
import sys, unicodedata
sys.stdout.reconfigure(errors="surrogateescape")
seen = set()
with open(sys.argv[1], encoding="utf-8", errors="surrogateescape") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        # macOS stores names in NFD; the server may hold NFC (Cyberduck normalised). List both spellings
        # so rclone's --files-from finds the file on either side; it pairs them with normalised comparison.
        for form in (line, unicodedata.normalize("NFC", line), unicodedata.normalize("NFD", line)):
            if form not in seen:
                seen.add(form)
                print(form)
PY
}

versions_args() {   # --backup-dir: the remote copy of an overwritten file is moved (server-side) into a dated snapshot folder
  VERSION_ARGS=(); (( VERSIONS_KEEP_DAYS > 0 )) && VERSION_ARGS=(--backup-dir "$VERSIONS_REMOTE/$(/bin/date -r "$START" +%Y-%m-%d_%H%M)")
}
prune_versions() {   # drop snapshot folders older than VERSIONS_KEEP_DAYS
  (( VERSIONS_KEEP_DAYS > 0 )) || return 0
  local cutoff d de n=0 kept=0; cutoff=$(( $(now) - VERSIONS_KEEP_DAYS * 86400 ))
  while IFS= read -r d; do
    d=${d%/}; [[ "$d" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})([0-9]{2})$ ]] || continue
    de=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:00" +%s 2>/dev/null) || continue
    if (( de < cutoff )); then tmo 600 rclone --config "$RCLONE_CONF" purge "$VERSIONS_REMOTE/$d" 2>>"$RUN_DIR/rclone-stderr.txt" && n=$((n+1)); else kept=$((kept+1)); fi
  done < <(tmo 120 rclone --config "$RCLONE_CONF" lsf --dirs-only "$VERSIONS_REMOTE" 2>/dev/null)
  log "versions: $kept snapshot folder(s) kept$( (( n > 0 )) && echo ", $n older than $VERSIONS_KEEP_DAYS days removed")"
}
COPY_EXIT=0
do_copy() {   # do_copy <dry 0/1> <files-from list or "">
  local dry=$1 list=$2 t0; local -a args=(copy "$LOCAL_DIR" "$REMOTE")
  versions_args; args+=(${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"})
  [[ "$COMPARE_MODE" == update ]] && args+=(--update)
  args+=(--transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" --no-update-dir-modtime
         "${RC_NET[@]}" "${RC_LOG[@]}" --log-file "$RUN_DIR/rclone-copy.jsonl" ${RCLONE_EXTRA[@]+"${RCLONE_EXTRA[@]}"})
  # rclone forbids combining --files-from-raw with other filters; the list was built with the filters applied
  if [[ -n "$list" ]]; then args+=(--skip-links --files-from-raw "$list"); else args+=("${FILTER_ARGS[@]}"); fi
  (( dry )) && args+=(--dry-run)
  log "rclone copy → $REMOTE  [$MODE$( [[ -n "$list" ]] && echo ", $WIN_COUNT candidate files")$( (( dry )) && echo ", DRY RUN")]  (rclone-copy.jsonl)"
  t0=$(now)
  run_rclone "${args[@]}"; COPY_EXIT=$?
  parse_stats "$RUN_DIR/rclone-copy.jsonl"
  log "copy finished in $(fmt_dur $(( $(now) - t0 ))): exit $COPY_EXIT ($(rclone_exit_msg "$COPY_EXIT")); $ST_TRANSFERS files / $(fmt_bytes "$ST_BYTES") transferred, $ST_CHECKS compared, $ST_ERRORS errors"
  digest_copy "$RUN_DIR/rclone-copy.jsonl" "$dry"
}

CK_EXIT=0; CK_MISSING=0; CK_DIFFER=0; CK_ERRORS=0; CHECK_DONE=0
do_check() {   # do_check <tag> <files-from list or "">  — rclone check --one-way --size-only
  local tag=$1 list=$2 t0 s
  local -a args=(check "$LOCAL_DIR" "$REMOTE" --one-way --size-only --checkers "$RCLONE_CHECKERS"
                 "${RC_NET[@]}" "${RC_LOG[@]}" --log-file "$RUN_DIR/rclone-check-$tag.jsonl"
                 --missing-on-dst "$RUN_DIR/check-$tag-missing.txt" --differ "$RUN_DIR/check-$tag-differ.txt"
                 --error "$RUN_DIR/check-$tag-error.txt" ${RCLONE_EXTRA[@]+"${RCLONE_EXTRA[@]}"})
  if [[ -n "$list" ]]; then args+=(--skip-links --files-from-raw "$list"); else args+=("${FILTER_ARGS[@]}"); fi
  log "verify ($tag): rclone check --one-way --size-only$( [[ -n "$list" ]] && echo " on $WIN_COUNT files" || echo " on the whole tree")"
  t0=$(now)
  run_rclone "${args[@]}"; CK_EXIT=$?
  CK_MISSING=$(count_lines "$RUN_DIR/check-$tag-missing.txt"); CK_DIFFER=$(count_lines "$RUN_DIR/check-$tag-differ.txt"); CK_ERRORS=$(count_lines "$RUN_DIR/check-$tag-error.txt")
  s=$(jq -Rr 'fromjson? | select(.stats) | .stats.checks // 0' "$RUN_DIR/rclone-check-$tag.jsonl" 2>/dev/null | tail -n 1)
  if (( CK_EXIT == 0 )) || { (( CK_EXIT == 1 )) && [[ -n "$s" ]]; }; then CHECK_DONE=1; else CHECK_DONE=0; fi   # exit 1 without stats = usage error
  log "verify ($tag) finished in $(fmt_dur $(( $(now) - t0 ))): exit $CK_EXIT; ${s:-?} files compared, $CK_MISSING missing on remote, $CK_DIFFER size differs, $CK_ERRORS errors"
  (( CK_MISSING > 0 )) && { log "  missing on remote:"; head -n 50 "$RUN_DIR/check-$tag-missing.txt" | sed 's/^/    /' >> "$RUN_LOG"; }
  (( CK_DIFFER  > 0 )) && { log "  size differs:";      head -n 50 "$RUN_DIR/check-$tag-differ.txt"  | sed 's/^/    /' >> "$RUN_LOG"; }
  (( CK_ERRORS  > 0 )) && { log "  errors:";            head -n 20 "$RUN_DIR/check-$tag-error.txt"   | sed 's/^/    /' >> "$RUN_LOG"; }
  return 0
}

BUSY_COUNT=0
split_busy() {   # split_busy <tag>: files that changed locally while this run was going are "in use", not failures
  local f="$RUN_DIR/check-$1-differ.txt" b="$RUN_DIR/check-$1-busy.txt" keep="$RUN_DIR/check-$1-differ.real.txt" rel m n
  : > "$b"; : > "$keep"; [[ -s "$f" ]] || return 0
  while IFS= read -r rel; do
    m=$(/usr/bin/stat -f %m "$LOCAL_DIR/$rel" 2>/dev/null || echo 0)
    if (( m >= START - 5 )); then printf '%s\n' "$rel" >> "$b"; else printf '%s\n' "$rel" >> "$keep"; fi
  done < "$f"
  mv "$keep" "$f"; CK_DIFFER=$(count_lines "$f"); n=$(count_lines "$b"); BUSY_COUNT=$(( BUSY_COUNT + n ))
  if (( n > 0 )); then log "  $n file(s) still being written during the run (logs, autosave…) — not counted, picked up next run:"; head -n 20 "$b" | sed 's/^/    /' >> "$RUN_LOG"; fi
}
FIX_EXIT=0; FIX_TRANSFERS=0; FIX_BYTES=0; FIX_ERRORS=0
do_fix() {   # do_fix <check tag> — re-upload what the check found missing/differing (size-based, no --update)
  local tag=$1 n
  cat "$RUN_DIR/check-$tag-missing.txt" "$RUN_DIR/check-$tag-differ.txt" 2>/dev/null | grep . > "$RUN_DIR/fix-list.txt"
  n=$(count_lines "$RUN_DIR/fix-list.txt"); (( n > 0 )) || return 0
  log "re-uploading $n file(s) that failed verification"
  versions_args
  local -a args=(copy "$LOCAL_DIR" "$REMOTE" ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} --skip-links --files-from-raw "$RUN_DIR/fix-list.txt" --transfers "$RCLONE_TRANSFERS"
                 --checkers "$RCLONE_CHECKERS" --no-update-dir-modtime "${RC_NET[@]}" "${RC_LOG[@]}"
                 --log-file "$RUN_DIR/rclone-fix.jsonl" ${RCLONE_EXTRA[@]+"${RCLONE_EXTRA[@]}"})
  run_rclone "${args[@]}"; FIX_EXIT=$?
  parse_stats "$RUN_DIR/rclone-fix.jsonl"; FIX_TRANSFERS=$ST_TRANSFERS; FIX_BYTES=$ST_BYTES; FIX_ERRORS=$ST_ERRORS
  jq -Rr 'fromjson? | select(.level=="error") | "\(.object // "-"): \(.msg)"' "$RUN_DIR/rclone-fix.jsonl" >> "$RUN_DIR/errors.txt"
  log "re-upload finished: exit $FIX_EXIT ($(rclone_exit_msg "$FIX_EXIT")); $FIX_TRANSFERS files / $(fmt_bytes "$FIX_BYTES")"
}

prune_logs() { /usr/bin/find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????*' -mtime +"$LOG_KEEP_DAYS" -exec rm -rf {} + 2>/dev/null; return 0; }

# ----------------------------------------------------------------------------- feedback
notify() {   # notify <ok|warn|fail|stale> <title> <message>
  local level=$1 title=$2 msg=$3 logfile="$LOG_DIR/latest/run.log"
  [[ "$NOTIFY" == true ]] || return 0
  if [[ "$level" == ok ]]; then
    case "$NOTIFY_ON_SUCCESS" in true) ;; daily) is_main_slot || return 0 ;; *) return 0 ;; esac
  fi
  local quiet=0; [[ "$level" == ok || "$level" == partial ]] && quiet=1      # no sound, no dialog
  if have terminal-notifier; then
    # shellcheck disable=SC2046
    terminal-notifier -title "$title" -message "$msg" -group "$LAUNCHD_LABEL" -execute "open -a Console '$logfile'" \
      $( (( ! quiet )) && echo "-sound default" ) >/dev/null 2>&1 </dev/null
  else
    osascript -e "display notification \"$(osa_esc "$msg")\" with title \"$(osa_esc "$title")\"" >/dev/null 2>&1
  fi
  if (( ! quiet )) && [[ "$FAILURE_DIALOG" == true ]]; then
    ( osascript -e "tell application \"System Events\" to display dialog \"$(osa_esc "$title")\n\n$(osa_esc "$msg")\" with title \"$(osa_esc "$BACKUP_NAME")\" buttons {\"Open log\", \"OK\"} default button \"OK\" with icon caution giving up after 43200" 2>/dev/null \
        | grep -q "Open log" && open -a Console "$logfile" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  return 0
}
check_stale() {
  local ls lp inst ref n ln; ls=$(state_get last_success_epoch 0); lp=$(state_get last_partial_epoch 0); inst=$(state_get installed_epoch 0); n=$(now)
  ref=$ls; (( lp > ref )) && ref=$lp; (( ref == 0 )) && ref=$inst; (( ref == 0 )) && return 0
  (( n - ref > STALE_AFTER_HOURS * 3600 )) || return 0
  ln=$(state_get last_stale_notified_epoch 0)
  if (( n - ln > 86400 )); then
    notify stale "$BACKUP_NAME is STALE" "No successful backup since $(fmt_epoch "$ls"). Last result: $(state_get last_result none) — $(state_get last_message '-'). Run 'backup.sh status'."
    state_set last_stale_notified_epoch "$n"
  fi
}

# ----------------------------------------------------------------------------- record + finish
RESULT=""; RESULT_MSG=""; MODE=""; DRY=0; RUN_REASON="manual"; START=0; START_ISO=""
TOTAL_TRANSFERS=0; TOTAL_BYTES=0; ST_CHECKS_COPY=0; ST_ERRORS_COPY=0; ERR_COUNT=0
record_run() {   # record_run <duration_s>
  jq -cn --arg start "$START_ISO" --arg end "$(iso)" --arg mode "$MODE" --arg result "$RESULT" --arg msg "$RESULT_MSG" \
     --arg reason "$RUN_REASON" --arg log "$RUN_DIR" --argjson dry "$DRY" --argjson dur "$1" --argjson cexit "$COPY_EXIT" \
     --argjson tr "$TOTAL_TRANSFERS" --argjson by "$TOTAL_BYTES" --argjson ch "$ST_CHECKS_COPY" --argjson er "$ERR_COUNT" \
     --argjson win "$WIN_COUNT" --argjson ckexit "$CK_EXIT" --argjson miss "$CK_MISSING" --argjson diff "$CK_DIFFER" --argjson ckdone "$CHECK_DONE" \
     '{start:$start,end:$end,duration_s:$dur,reason:$reason,mode:$mode,dry_run:($dry==1),result:$result,message:$msg,
       rclone_exit:$cexit,transfers:$tr,bytes:$by,checks:$ch,errors:$er,window_files:$win,
       verified:($ckdone==1),check_exit:$ckexit,check_missing:$miss,check_differ:$diff,log:$log}' >> "$RUNS_FILE"
}
finish() {   # finish <ok|warn|fail|dry|check> <message>  — records, updates state, notifies, exits
  RESULT=$1; RESULT_MSG=$2
  local n dur; n=$(now); dur=$(( n - START ))
  log "result: ${RESULT^^} — $RESULT_MSG  (total $(fmt_dur "$dur"))"
  record_run "$dur"
  if [[ "$RESULT" == check ]]; then
    (( CHECK_DONE )) && state_set last_check_epoch "$n" last_check_missing "$CK_MISSING" last_check_differ "$CK_DIFFER"
  elif [[ "$RESULT" != dry ]]; then
    state_set last_attempt_epoch "$n" last_result "$RESULT" last_message "$RESULT_MSG" last_mode "$MODE" last_run_dir "$RUN_DIR" \
              last_transfers "$TOTAL_TRANSFERS" last_bytes "$TOTAL_BYTES" last_duration "$dur"
    if [[ "$RUN_REASON" == retry ]]; then state_set retries_since_slot "$(( $(state_get retries_since_slot 0) + 1 ))"; else state_set retries_since_slot 0; fi
    case "$RESULT" in
      partial) state_set last_partial_epoch "$n" failures_in_row 0 ;;
      ok|warn)
        state_set last_success_epoch "$n" failures_in_row 0
        (( CHECK_DONE )) && state_set last_check_epoch "$n" last_check_missing "$CK_MISSING" last_check_differ "$CK_DIFFER"
        [[ "$MODE" == full ]] && (( CHECK_DONE )) && state_set last_full_success_epoch "$n" ;;
      fail) state_set failures_in_row "$(( $(state_get failures_in_row 0) + 1 ))" ;;
    esac
  fi
  case "$RESULT" in
    ok)      notify ok      "$BACKUP_NAME: OK"      "$RESULT_MSG" ;;
    partial) notify partial "$BACKUP_NAME: partial" "$RESULT_MSG" ;;
    warn)    notify warn    "$BACKUP_NAME: WARNING" "$RESULT_MSG" ;;
    fail)
      local fr ln; fr=$(state_get failures_in_row 0); ln=$(state_get last_failure_notified_epoch 0)
      if (( fr <= 1 || n - ln > 86400 )); then notify fail "$BACKUP_NAME: FAILED" "$RESULT_MSG"; state_set last_failure_notified_epoch "$n"; fi ;;
  esac
  lock_release
  case "$RESULT" in
    fail) exit 1 ;;
    check) if (( ! CHECK_DONE || CK_MISSING + CK_DIFFER > 0 )); then exit 1; else exit 0; fi ;;
    *) exit 0 ;;
  esac
}
start_run_dir() {   # start_run_dir <suffix>
  START=$(now); START_ISO=$(iso)
  local base i=1; base="$LOG_DIR/$(/bin/date -r "$START" +%Y-%m-%d_%H%M%S)$1"; RUN_DIR=$base
  while [[ -e "$RUN_DIR" ]]; do RUN_DIR="$base-$i"; i=$((i+1)); done
  mkdir -p "$RUN_DIR"; RUN_LOG="$RUN_DIR/run.log"
  ln -sfn "$RUN_DIR" "$LOG_DIR/latest"
  : > "$RUN_DIR/errors.txt"
}

# ----------------------------------------------------------------------------- commands
cmd_run() {
  local FORCE_MODE=""; DRY=0; RUN_REASON="manual"
  while (( $# )); do
    case "$1" in
      --full) FORCE_MODE=full;; --incremental) FORCE_MODE=incremental;; --dry-run|-n) DRY=1;;
      --reason) RUN_REASON=$2; shift;; -h|--help) usage; exit 0;; *) die "unknown option for run: $1";;
    esac; shift
  done
  require rclone jq python3
  state_init
  [[ -d "$LOCAL_DIR" ]] || die "LOCAL_DIR does not exist: $LOCAL_DIR"
  lock_acquire || die "a backup run is already in progress (pid $(lock_pid)); see $LOG_DIR/latest/run.log"
  trap on_signal INT TERM; trap lock_release EXIT
  start_run_dir ""; prune_logs
  log "backup run start ($RUN_REASON)  $LOCAL_DIR → $REMOTE  host=$(hostname -s)  pid=$$"
  (( DRY )) && log "DRY RUN — nothing will be uploaded"

  # 1. credentials + remote reachable
  setup_rclone || finish fail "$KEYCHAIN_HINT"
  local t0; t0=$(now)
  if ! tmo 120 rclone --config "$RCLONE_CONF" lsf --max-depth 1 "$REMOTE_ROOT" >/dev/null 2>>"$RUN_DIR/rclone-stderr.txt"; then
    finish fail "remote not reachable: $REMOTE_ROOT — $(tail -n 1 "$RUN_DIR/rclone-stderr.txt" 2>/dev/null | cut -c1-200)"
  fi
  log "remote reachable ($REMOTE_ROOT, $(( $(now) - t0 ))s)"
  local q; q=$(remote_quota 2>/dev/null || true); [[ -n "$q" ]] && log "remote quota: $q"
  # write test: a full quota must fail fast here, not after hours of retried uploads
  printf 'rugbackup write test %s\n' "$(iso)" > "$RUN_DIR/.write-test"
  local wt_ec=1 wt_try
  for wt_try in 1 2; do     # the server sometimes needs minutes to accept the first PUT after a long session: be patient, retry once
    tmo 300 rclone --config "$RCLONE_CONF" copyto "$RUN_DIR/.write-test" "$REMOTE/.rugbackup-write-test" --retries 1 --low-level-retries 2 2>>"$RUN_DIR/rclone-stderr.txt"; wt_ec=$?
    (( wt_ec == 0 )) && break
    log "write test attempt $wt_try failed (exit $wt_ec$( (( wt_ec == 124 )) && echo ' = no answer within 300s'))$( (( wt_try == 1 )) && echo '; waiting 60s and retrying')"
    (( wt_try == 1 )) && sleep 60
  done
  if (( wt_ec != 0 )); then
    local why; why=$(tail -n 1 "$RUN_DIR/rclone-stderr.txt" 2>/dev/null | cut -c1-200)
    (( wt_ec == 124 )) && why="server did not complete a 46-byte upload within 300 s (twice)${why:+; last rclone message: $why}"
    if grep -qiE '507|insufficient storage|quota' <<<"$why"; then state_set quota_full_epoch "$(now)"; finish fail "remote storage is FULL (write test refused: $why). Free space or raise the quota; scheduled runs pause for 24 h, 'backup.sh run' works any time."; fi
    finish fail "remote refuses writes: ${why:-rclone exit $wt_ec, no message}"
  fi
  tmo 60 rclone --config "$RCLONE_CONF" deletefile "$REMOTE/.rugbackup-write-test" 2>>"$RUN_DIR/rclone-stderr.txt" || log "note: could not delete the write-test file on the remote"
  log "write test ok ($(( $(now) - t0 ))s incl. connectivity check)"
  state_set quota_full_epoch 0

  # 2. mode
  local ls lf n why list=""; ls=$(state_get last_success_epoch 0); lf=$(state_get last_full_success_epoch 0); n=$(now)
  if   [[ "$FORCE_MODE" == full ]]; then MODE=full; why="requested"
  elif [[ "$FORCE_MODE" == incremental ]]; then MODE=incremental; why="requested"
  elif (( lf == 0 )); then MODE=full; why="no full run yet"
  elif (( n - lf >= FULL_EVERY_DAYS * 86400 )) && { is_main_slot || (( n - lf >= (FULL_EVERY_DAYS + 2) * 86400 )); }; then MODE=full; why="last full run $(fmt_ago "$lf")"
  elif (( ls == 0 )); then MODE=full; why="no successful run yet"
  else MODE=incremental; why="last success $(fmt_ago "$ls")"; fi
  if [[ "$MODE" == incremental ]]; then
    local window_h; if (( ls == 0 )); then window_h=$(( FULL_EVERY_DAYS * 24 )); else window_h=$(( (n - ls) / 3600 + 2 )); fi
    make_window_list "$window_h" || finish fail "could not list $LOCAL_DIR (see rclone-stderr.txt)"
    log "mode: incremental ($why) — $WIN_COUNT files modified in the last ${window_h}h"
    if (( WIN_COUNT > INCREMENTAL_MAX_FILES )); then MODE=full; log "mode: switching to full — $WIN_COUNT changed files exceed INCREMENTAL_MAX_FILES=$INCREMENTAL_MAX_FILES"
    else list="$RUN_DIR/window-files.txt"; fi
  fi
  [[ "$MODE" == full ]] && log "mode: full ($why) — comparing the whole tree"

  # 3. copy
  if [[ "$MODE" == incremental && "$WIN_COUNT" == 0 ]]; then
    log "nothing changed since the last successful run — no upload needed"; COPY_EXIT=0
  else
    do_copy "$DRY" "$list"; TOTAL_TRANSFERS=$ST_TRANSFERS; TOTAL_BYTES=$ST_BYTES; ST_CHECKS_COPY=$ST_CHECKS; ST_ERRORS_COPY=$ST_ERRORS
  fi
  ERR_COUNT=$(count_lines "$RUN_DIR/errors.txt")
  (( DRY )) && finish dry "would upload $TOTAL_TRANSFERS files / $(fmt_bytes "$TOTAL_BYTES") ($MODE); $(rclone_exit_msg "$COPY_EXIT"), $ERR_COUNT error(s)"
  if (( COPY_EXIT == 124 || COPY_EXIT == 137 )); then
    finish partial "time limit $RCLONE_MAX_RUNTIME reached after uploading $TOTAL_TRANSFERS files / $(fmt_bytes "$TOTAL_BYTES") ($MODE); the next run continues where this one stopped"
  fi

  prune_versions
  # 4. verify (+ repair)
  local tag
  if [[ "$MODE" == full ]]; then tag=full; do_check full ""; split_busy full
  elif (( WIN_COUNT > 0 )); then tag=window; do_check window "$list"; split_busy window
  else CHECK_DONE=1; CK_EXIT=0; fi
  if (( CHECK_DONE && CK_EXIT == 1 && CK_MISSING + CK_DIFFER > 0 )); then
    do_fix "$tag"
    TOTAL_TRANSFERS=$(( TOTAL_TRANSFERS + FIX_TRANSFERS )); TOTAL_BYTES=$(( TOTAL_BYTES + FIX_BYTES ))
    WIN_COUNT_SAVE=$WIN_COUNT; WIN_COUNT=$(count_lines "$RUN_DIR/fix-list.txt"); do_check fixed "$RUN_DIR/fix-list.txt"; split_busy fixed; WIN_COUNT=$WIN_COUNT_SAVE
  fi
  local err_lines; err_lines=$(grep -vc '^-: Attempt' "$RUN_DIR/errors.txt" 2>/dev/null || true)
  ERR_COUNT=$(( ST_ERRORS_COPY + FIX_ERRORS ))          # errors left after rclone's own retries (copy pass + fix pass)
  (( err_lines > ERR_COUNT )) && log "$(( err_lines - ERR_COUNT )) transient error(s) were resolved by rclone's retries (details in errors.txt)"

  # 5. verdict
  local summary; summary="$TOTAL_TRANSFERS files / $(fmt_bytes "$TOTAL_BYTES") uploaded, $MODE, $(fmt_dur $(( $(now) - START )))"
  if (( COPY_EXIT != 0 )) && grep -qiE '507|insufficient storage|quota' "$RUN_DIR/errors.txt"; then
    state_set quota_full_epoch "$(now)"
    finish fail "remote storage is FULL: $(grep -ciE '507|insufficient storage|quota' "$RUN_DIR/errors.txt") uploads refused; $summary. Free space or raise the quota; scheduled runs pause for 24 h — see $RUN_DIR/run.log"
  fi
  if (( COPY_EXIT != 0 )); then finish fail "$(rclone_exit_msg "$COPY_EXIT"); $ERR_COUNT error(s); $summary — see $RUN_DIR/run.log"
  elif (( ! CHECK_DONE )); then finish warn "upload finished but verification did not complete ($(rclone_exit_msg "$CK_EXIT")); $summary"
  elif (( FIX_EXIT != 0 )); then finish warn "re-upload of $(count_lines "$RUN_DIR/fix-list.txt") unverified file(s) failed ($(rclone_exit_msg "$FIX_EXIT")); $summary — see $RUN_DIR/run.log"
  elif (( CK_MISSING + CK_DIFFER > 0 )); then finish warn "$(( CK_MISSING + CK_DIFFER )) file(s) still wrong on the remote after re-upload; $summary — see $RUN_DIR/run.log"
  elif [[ "$MODE" == full ]]; then finish ok "$summary; whole tree verified$( (( BUSY_COUNT > 0 )) && echo " ($BUSY_COUNT file(s) in use, next run)")"
  elif (( WIN_COUNT > 0 )); then finish ok "$summary; $WIN_COUNT changed files verified$( (( BUSY_COUNT > 0 )) && echo " ($BUSY_COUNT in use, next run)")"
  else finish ok "nothing changed since the last run ($(fmt_dur $(( $(now) - START ))))"; fi
}

cmd_check() {
  require rclone jq python3; state_init
  lock_acquire || die "a backup run is in progress (pid $(lock_pid)); try again later"
  trap on_signal INT TERM; trap lock_release EXIT
  start_run_dir "-check"; MODE=check
  log "verification only: $LOCAL_DIR vs $REMOTE (presence + size; nothing is uploaded)"
  setup_rclone || { log "$KEYCHAIN_HINT"; lock_release; die "$KEYCHAIN_HINT"; }
  do_check full ""
  ERR_COUNT=$CK_ERRORS
  (( CHECK_DONE )) || finish check "verification did not complete ($(rclone_exit_msg "$CK_EXIT"))"
  finish check "$CK_MISSING missing, $CK_DIFFER differing on the remote (lists in $RUN_DIR)"
}

slot_hours() { printf '%s\n' $RUN_HOURS "$RUN_HOUR" | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' '; }   # run slots (local hours), RUN_HOUR always included
slot_epoch() {   # most recent run slot <= now
  local n day h e best=0; n=$(now)
  for day in "$(/bin/date -v-1d +%Y-%m-%d)" "$(/bin/date +%Y-%m-%d)"; do
    for h in $(slot_hours); do e=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$day $(printf '%02d' "$h"):00:00" +%s); (( e <= n && e > best )) && best=$e; done
  done
  echo "$best"
}
next_slot_epoch() {   # first run slot > now
  local n day h e best=0; n=$(now)
  for day in "$(/bin/date +%Y-%m-%d)" "$(/bin/date -v+1d +%Y-%m-%d)"; do
    for h in $(slot_hours); do e=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$day $(printf '%02d' "$h"):00:00" +%s); (( e > n )) && { (( best == 0 || e < best )) && best=$e; }; done
  done
  echo "$best"
}
is_main_slot() { [[ "$(/bin/date -r "$(slot_epoch)" +%H)" == "$(printf '%02d' "$RUN_HOUR")" ]]; }   # the RUN_HOUR slot: full passes, daily notification
cmd_tick() {
  state_init
  [[ "$(state_get paused 0)" == 1 ]] && exit 0
  lock_running && exit 0
  check_stale
  local n slot la lr reason=""; n=$(now); slot=$(slot_epoch); la=$(state_get last_attempt_epoch 0); lr=$(state_get last_result none)
  (( n - $(state_get quota_full_epoch 0) < 86400 )) && exit 0     # remote was full: wait a day, no retries
  if (( la < slot )); then reason=scheduled
  elif [[ "$lr" == fail || "$lr" == partial ]] && (( n - la >= RETRY_AFTER_HOURS * 3600 )) && (( $(state_get retries_since_slot 0) < MAX_RETRIES )); then reason=retry
  fi
  [[ -n "$reason" ]] || exit 0
  cmd_run --reason "$reason"
}

cmd_status() {
  state_init
  local uid agent la lr ls lf lc n fr ref; uid=$(id -u); n=$(now)
  if launchctl print "gui/$uid/$LAUNCHD_LABEL" >/dev/null 2>&1; then agent="loaded — wakes hourly at :$(printf '%02d' "$TICK_MINUTE"), runs after $(slot_hours | sed 's/ $//; s/ /h, /g')h, full run every $FULL_EVERY_DAYS days at $(printf '%02d' "$RUN_HOUR")h"; else agent="NOT installed (run: backup.sh install)"; fi
  la=$(state_get last_attempt_epoch 0); lr=$(state_get last_result none); ls=$(state_get last_success_epoch 0); lf=$(state_get last_full_success_epoch 0); lc=$(state_get last_check_epoch 0)
  echo "$BACKUP_NAME   $LOCAL_DIR  →  $REMOTE$( [[ -n "$FILTER_FILE" ]] && echo "   (parts: $(grep -cE '^\+' "$FILTER_FILE") include rule(s) in $(basename "$FILTER_FILE"))")"
  echo "  agent:            $agent$( [[ "$(state_get paused 0)" == 1 ]] && echo '  [PAUSED — backup.sh resume]')"
  lock_running && echo "  running now:      yes (pid $(lock_pid)) — tail -f '$LOG_DIR/latest/run.log'"
  echo "  last attempt:     $(fmt_epoch "$la")  ${lr^^}  $(state_get last_mode -)  $(fmt_dur "$(state_get last_duration 0)")  $(state_get last_transfers 0) files / $(fmt_bytes "$(state_get last_bytes 0)")"
  [[ "$lr" != ok && "$lr" != none ]] && echo "                    $(state_get last_message -)"
  echo "  last success:     $(fmt_epoch "$ls")$( (( ls > 0 )) && echo "  ($(fmt_ago "$ls"))")"
  echo "  last full+verify: $(fmt_epoch "$lf")$( (( lf > 0 )) && echo "  → next full due $(fmt_epoch $(( lf + FULL_EVERY_DAYS * 86400 )))")"
  echo "  last verify:      $(fmt_epoch "$lc")  missing $(state_get last_check_missing -), size differs $(state_get last_check_differ -)"
  fr=$(state_get failures_in_row 0); (( fr > 0 )) && echo "  failures in row:  $fr"
  ref=$ls; (( $(state_get last_partial_epoch 0) > ref )) && ref=$(state_get last_partial_epoch 0); (( ref == 0 )) && ref=$(state_get installed_epoch 0)
  (( ref > 0 && n - ref > STALE_AFTER_HOURS * 3600 )) && echo "  ⚠ STALE:          no successful backup for $(( (n - ref) / 3600 )) h"
  if (( n - $(state_get quota_full_epoch 0) < 86400 )); then echo "  ⚠ REMOTE FULL:    uploads refused $(fmt_ago "$(state_get quota_full_epoch 0)"); automatic runs paused for 24 h"; fi
  local q=""; if [[ -n "$WEBDAV_URL$REMOTE_OVERRIDE" ]] && setup_rclone 2>/dev/null; then q=$(remote_quota 2>/dev/null || true); fi; [[ -n "$q" ]] && echo "  remote quota:     $q"
  (( VERSIONS_KEEP_DAYS > 0 )) && echo "  versions:         overwritten files kept $VERSIONS_KEEP_DAYS days in $VERSIONS_REMOTE  (backup.sh versions <name>)"
  echo "  next scheduled:   $(fmt_epoch "$(next_slot_epoch)") (first hourly wake-up after that; slots at $(slot_hours| sed 's/ $//; s/ /h, /g')h, full pass at $(printf '%02d' "$RUN_HOUR"):00)"
  echo "  logs:             $LOG_DIR   latest: $(readlink "$LOG_DIR/latest" 2>/dev/null | xargs -I{} basename {} || echo -)"
  if [[ -s "$RUNS_FILE" ]]; then
    echo; echo "Recent runs:"
    { printf 'START\tREASON\tMODE\tRESULT\tFILES\tBYTES\tDURATION\tERRORS\tMISSING/DIFFER\n'
      tail -n 12 "$RUNS_FILE" | jq -r '
        def hb: if . < 1024 then "\(.) B" elif . < 1048576 then "\((./1024*10|floor)/10) KiB" elif . < 1073741824 then "\((./1048576*10|floor)/10) MiB" else "\((./1073741824*10|floor)/10) GiB" end;
        [ (.start|.[0:16]|sub("T";" ")), .reason, (.mode + (if .dry_run then "(dry)" else "" end)), .result, .transfers, (.bytes|hb), "\(.duration_s)s", .errors, (if .verified then "\(.check_missing)/\(.check_differ)" else "n/a" end) ] | @tsv'
    } | column -t -s $'\t'
  fi
}

cmd_log() {
  local n=${1:-1} d
  d=$(ls -1d "$LOG_DIR"/20*/ 2>/dev/null | sort | tail -n "$n" | head -n 1); [[ -n "$d" ]] || die "no runs yet in $LOG_DIR"
  echo "== ${d%/}"; cat "$d/run.log"
}

cmd_setup() {
  require security rclone
  [[ -n "$WEBDAV_USER" ]] || die "WEBDAV_USER is not set in $CONF"
  echo "Storing the WebDAV password for $WEBDAV_USER as login-keychain item '$KEYCHAIN_SERVICE'."
  echo "(Do this in a Terminal on the Mac itself — over SSH the keychain is locked.)"
  security add-generic-password -a "$WEBDAV_USER" -s "$KEYCHAIN_SERVICE" -l "RUG WebDAV backup ($WEBDAV_USER)" \
      -j "read by $SCRIPT_PATH" -T /usr/bin/security -U || die "could not store the item (keychain locked? try: security unlock-keychain)"
  printf 'read-back without a prompt: '
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$WEBDAV_USER" -w >/dev/null 2>&1; then echo OK; else echo "FAILED — if a dialog asked for permission, choose 'Always Allow' and re-run setup"; fi
  printf 'connection test: '
  local err; err=$(mktemp)
  if setup_rclone && tmo 90 rclone --config "$RCLONE_CONF" lsf --max-depth 1 "$REMOTE_ROOT" >/dev/null 2>"$err"; then echo "OK ($REMOTE_ROOT)"; rm -f "$err"
  else echo "FAILED — rclone said:"; sed 's/^/   /' "$err" | tail -n 8; rm -f "$err"; echo "   (check WEBDAV_URL / WEBDAV_USER / password; proxy or RCLONE_* variables in this shell can interfere: env | grep -iE 'proxy|rclone')"; exit 1; fi
}

cmd_install() {
  require rclone jq python3
  local uid plist; uid=$(id -u); plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
  [[ -x "$BASH_BIN" ]] || die "BASH_BIN not found: $BASH_BIN"
  state_init; mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_esc "$BASH_BIN")</string>
        <string>$(xml_esc "$SCRIPT_PATH")</string>
        <string>tick</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>BACKUP_CONF</key><string>$(xml_esc "$CONF")</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict><key>Minute</key><integer>$TICK_MINUTE</integer></dict>
    <key>RunAtLoad</key><true/>
    <key>AbandonProcessGroup</key><true/>
    <key>Nice</key><integer>5</integer>
    <key>StandardOutPath</key><string>$(xml_esc "$LOG_DIR/launchd.log")</string>
    <key>StandardErrorPath</key><string>$(xml_esc "$LOG_DIR/launchd.log")</string>
</dict>
</plist>
EOF
  plutil -lint "$plist" >/dev/null || die "generated plist is invalid: $plist"
  launchctl bootout "gui/$uid/$LAUNCHD_LABEL" 2>/dev/null
  launchctl bootstrap "gui/$uid" "$plist" || die "launchctl bootstrap failed"
  launchctl enable "gui/$uid/$LAUNCHD_LABEL"
  [[ "$(state_get installed_epoch 0)" == 0 ]] && state_set installed_epoch "$(now)"
  echo "installed $plist"
  echo "launchd wakes the script hourly at :$(printf '%02d' "$TICK_MINUTE"); the daily backup runs at the first wake-up after $(printf '%02d' "$RUN_HOUR"):00."
  [[ "$(state_get paused 0)" == 1 ]] && echo "note: scheduled runs are PAUSED (backup.sh resume)"
  return 0
}
cmd_uninstall() {
  local uid; uid=$(id -u)
  for l in "$LAUNCHD_LABEL" "$LAUNCHD_LABEL.once"; do launchctl bootout "gui/$uid/$l" 2>/dev/null; rm -f "$HOME/Library/LaunchAgents/$l.plist"; done
  echo "agent removed; state and logs kept in '$STATE_DIR' and '$LOG_DIR'"
}

cmd_gui_run() {   # run a command inside the GUI login session via a one-shot launchd job (keychain is unlocked there)
  local wait_flag=0 uid label plist out; local -a cmd_args=()
  while (( $# )); do case "$1" in --wait) wait_flag=1;; *) cmd_args+=("$1");; esac; shift; done
  (( ${#cmd_args[@]} )) || cmd_args=(run)
  uid=$(id -u); label="$LAUNCHD_LABEL.once"; plist="$HOME/Library/LaunchAgents/$label.plist"; out="$LOG_DIR/gui-run.log"
  [[ -x "$BASH_BIN" ]] || die "BASH_BIN not found: $BASH_BIN"
  state_init; mkdir -p "$HOME/Library/LaunchAgents"
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 && die "a gui-run job is still running ($label); wait for it or: launchctl bootout gui/$uid/$label"
  : > "$out"
  local args_xml="" a; for a in "${cmd_args[@]}"; do args_xml+="        <string>$(xml_esc "$a")</string>"$'\n'; done
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_esc "$BASH_BIN")</string>
        <string>-c</string>
        <string>"\$1" "\${@:4}"; echo "[gui-run: exit \$?]"; rm -f "\$2"; launchctl bootout "gui/$uid/\$3"</string>
        <string>rugbackup-once</string>
        <string>$(xml_esc "$SCRIPT_PATH")</string>
        <string>$(xml_esc "$plist")</string>
        <string>$label</string>
$args_xml    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>BACKUP_CONF</key><string>$(xml_esc "$CONF")</string>
        <key>VERBOSE</key><string>1</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>AbandonProcessGroup</key><true/>
    <key>StandardOutPath</key><string>$(xml_esc "$out")</string>
    <key>StandardErrorPath</key><string>$(xml_esc "$out")</string>
</dict>
</plist>
EOF
  plutil -lint "$plist" >/dev/null || die "generated plist is invalid: $plist"
  launchctl bootstrap "gui/$uid" "$plist" || die "launchctl bootstrap failed"
  echo "started '${cmd_args[*]}' inside the GUI login session (one-shot agent $label, removes itself when done)"
  echo "output: $out"
  if (( wait_flag )); then
    while launchctl print "gui/$uid/$label" >/dev/null 2>&1; do sleep 5; done
    echo; cat "$out"
  fi
}

cmd_probe() {   # cheap end-to-end test of the WebDAV server with rclone; safe: writes only into REMOTE/.rugbackup-probe
  require rclone jq curl; state_init
  local t0 t1 n d pw var tmp probe="$REMOTE/.rugbackup-probe"
  echo "== rugbackup probe  $(ts)  host=$(hostname -s)  rclone $(rclone version | head -n 1 | cut -d' ' -f2)"
  echo "-- 1. keychain"
  if setup_rclone; then echo "   password read from the login keychain: OK"; else echo "   FAIL: $KEYCHAIN_HINT"; return 1; fi
  echo "-- 2. server (authenticated OPTIONS on $WEBDAV_URL/)"
  var="RCLONE_CONFIG_${REMOTE_NAME^^}_PASS"; pw=$(rclone reveal "${!var}")
  printf 'user = "%s:%s"\n' "$WEBDAV_USER" "$pw" | curl -s -o /dev/null -D - --max-time 30 -X OPTIONS -K - "$WEBDAV_URL/" | grep -iE '^(HTTP|server|dav|allow|x-powered)' | sed 's/^/   /'
  unset pw
  echo "-- 3. list root  ($REMOTE_ROOT)"
  t0=$(now); rc lsf --max-depth 1 "$REMOTE_ROOT" 2>&1 | head -n 15 | sed 's/^/   /'; echo "   (${PIPESTATUS[0]} exit, $(( $(now) - t0 ))s)"
  echo "-- 4. list backup folder  ($REMOTE)"
  t0=$(now); n=$(rc lsf --max-depth 1 "$REMOTE" 2>&1 | tee /dev/stderr | wc -l); echo "   $n entries, $(( $(now) - t0 ))s"
  echo "-- 5. what the server reports per file (lsjson sample)"
  rc lsjson --files-only --max-depth 2 "$REMOTE" 2>&1 | jq -c '.[0:3][] | {Path, Size, ModTime}' 2>/dev/null | sed 's/^/   /'
  local sub; sub=$(rc lsf --dirs-only "$REMOTE" 2>/dev/null | head -n 1); sub=${sub%/}
  echo "-- 6. timing: recursive listing of $REMOTE/${sub:-?} (how long will a full-tree pass take?)"
  t0=$(now); d=$(rc lsf -R --dirs-only "$REMOTE/$sub" 2>/dev/null | wc -l); t1=$(( $(now) - t0 ))
  echo "   $d directories listed in ${t1}s → $(awk -v d="$d" -v t="$t1" 'BEGIN{ if (d>0) printf "%.2f", t/d; else print "?"}') s per directory"
  echo "   local tree has $(/usr/bin/find "$LOCAL_DIR" -type d 2>/dev/null | wc -l | tr -d ' ') directories → full pass ≈ $(awk -v d="$d" -v t="$t1" -v n="$(/usr/bin/find "$LOCAL_DIR" -type d 2>/dev/null | wc -l)" 'BEGIN{ if (d>0) printf "%.0f min", t/d*n/60; else print "?"}')"
  echo "-- 7. write test in $probe (upload, verify, --update rule, delete)"
  tmp=$(mktemp -d); mkdir -p "$tmp/p"
  printf 'probe %s\n' "$(ts)" > "$tmp/p/probe.txt"; printf 'umlaut\n' > "$tmp/p/Fürst & co (test) ü.txt"; head -c 3000000 /dev/urandom > "$tmp/p/3MB.bin"
  t0=$(now); rc copy "$tmp/p" "$probe" -v 2>&1 | grep -vE '^\s*$' | sed 's/^/   /'; echo "   upload exit ${PIPESTATUS[0]}, $(( $(now) - t0 ))s"
  echo "   remote now holds:"; rc lsjson "$probe" 2>&1 | jq -c '.[] | {Path, Size, ModTime}' 2>/dev/null | sed 's/^/     /'
  printf '   verify (check --one-way --size-only): '; rc check "$tmp/p" "$probe" --one-way --size-only 2>&1 | grep -E 'differences|matching|Failed|ERROR' | tr '\n' ' '; echo "→ exit ${PIPESTATUS[0]}"
  printf '   unchanged files with --update (expect 0 transfers): '; rc copy "$tmp/p" "$probe" --update --dry-run -v 2>&1 | grep -c 'Skipped copy'
  sleep 2; printf 'PROBE %s\n' "$(ts)" > "$tmp/p/probe.txt"   # same size, newer mtime
  printf '   same-size edit, newer locally, --update (expect 1 transfer): '; rc copy "$tmp/p" "$probe" --update --dry-run -v 2>&1 | grep -c 'Skipped copy'
  printf '   same-size edit, size-only mode (expect 0 — the known blind spot): '; rc copy "$tmp/p" "$probe" --size-only --dry-run -v 2>&1 | grep -c 'Skipped copy'
  printf '   cleanup (purge %s): ' "$probe"; if rc purge "$probe" 2>&1; then echo OK; fi
  rm -rf "$tmp"
  echo "== probe done $(ts)"
}

remote_quota() {   # prints "used/total (free)" if the server exposes RFC 4331 quota properties; empty otherwise
  local j; j=$(tmo 60 rclone --config "$RCLONE_CONF" about --json "$REMOTE_ROOT" 2>/dev/null) || return 1
  jq -r 'def hb: if . == null then "?" elif . < 1073741824 then "\((./1048576*10|floor)/10) MiB" elif . < 1099511627776 then "\((./1073741824*10|floor)/10) GiB" else "\((./1099511627776*100|floor)/100) TiB" end;
         if (.used == null and .free == null) then empty else "\(.used|hb) used of \(.total|hb), \(.free|hb) free" + (if .total and .used then " (\(.used*100/.total|floor)%)" else "" end) end' <<<"$j"
}
cmd_versions() {   # earlier versions of a file: backup.sh versions <name or glob>
  [[ -n "${1:-}" ]] || die "usage: backup.sh versions <file name or pattern>   (e.g. versions thesis.docx  or  versions 'Papers/**')"
  require rclone; state_init; setup_rclone || die "$KEYCHAIN_HINT"
  local pat=$1; [[ "$pat" == */* ]] || pat="*$pat"
  echo "versions of '$1' in $VERSIONS_REMOTE  (snapshot folder = time of the run that replaced the file):"
  rclone --config "$RCLONE_CONF" lsf -R --files-only --format "tsp" --separator "  " --include "$pat" "$VERSIONS_REMOTE" 2>/dev/null | sort
  echo "current copy:"; rclone --config "$RCLONE_CONF" lsf -R --files-only --format "tsp" --separator "  " --include "$pat" "$REMOTE" 2>/dev/null | sort | head -n 20
  echo "restore one with:  backup.sh rclone copyto '$VERSIONS_REMOTE/<snapshot>/<path>' ~/Desktop/<name>"
}

cmd_orphans() {   # files on the remote that no longer exist locally (or are excluded now): candidates for pruning
  require rclone jq python3; state_init
  lock_acquire || die "a backup run is in progress (pid $(lock_pid)); try again later"
  trap on_signal INT TERM; trap lock_release EXIT
  start_run_dir "-orphans"; MODE=orphans
  log "orphan report: what is on $REMOTE but not (any more) in $LOCAL_DIR"
  setup_rclone || { lock_release; die "$KEYCHAIN_HINT"; }
  local t0; t0=$(now)
  rclone --config "$RCLONE_CONF" lsf -R --files-only --format "sp" --separator $'\t' "$REMOTE" "${RC_NET[@]}" > "$RUN_DIR/remote-files.tsv" 2>>"$RUN_DIR/rclone-stderr.txt" || { log "remote listing failed"; lock_release; exit 1; }
  log "remote listed: $(count_lines "$RUN_DIR/remote-files.tsv") files in $(fmt_dur $(( $(now) - t0 )))"
  t0=$(now)
  rclone --config "$RCLONE_CONF" lsf -R --files-only "$LOCAL_DIR" "${FILTER_ARGS[@]}" > "$RUN_DIR/local-files.txt" 2>>"$RUN_DIR/rclone-stderr.txt" || { log "local listing failed"; lock_release; exit 1; }
  rclone --config "$RCLONE_CONF" lsf -R --files-only --skip-links "$LOCAL_DIR" > "$RUN_DIR/local-files-unfiltered.txt" 2>>"$RUN_DIR/rclone-stderr.txt"
  log "local listed: $(count_lines "$RUN_DIR/local-files.txt") files in scope, $(count_lines "$RUN_DIR/local-files-unfiltered.txt") on disk, $(fmt_dur $(( $(now) - t0 )))"
  python3 - "$RUN_DIR" <<'PYEOF' | tee -a "$RUN_LOG"
import sys, unicodedata, collections, os
d = sys.argv[1]; G = 1024**3
def nfc(x): return unicodedata.normalize("NFC", x)
def load(name):
    with open(os.path.join(d, name), encoding="utf-8", errors="surrogateescape") as fh:
        return {nfc(l.rstrip("\n")) for l in fh if l.strip()}
local = load("local-files.txt"); on_disk = load("local-files-unfiltered.txt")
gone = []; excluded = []
with open(os.path.join(d, "remote-files.tsv"), encoding="utf-8", errors="surrogateescape") as fh:
    for l in fh:
        size, _, path = l.rstrip("\n").partition("\t")
        if not path: continue
        n = nfc(path)
        if n in local: continue
        (excluded if n in on_disk else gone).append((int(size), path))
def report(title, rows, fn):
    tot = sum(s for s, _ in rows); per = collections.Counter(); cnt = collections.Counter()
    for s, p_ in rows:
        k = "/".join(p_.split("/")[:2]) if "/" in p_ else p_; per[k] += s; cnt[k] += 1
    print(f"\n{title}: {len(rows)} files, {tot/G:.1f} GiB")
    for k, v in per.most_common(15): print(f"  {v/G:7.1f} GiB {cnt[k]:8d} files  {k}")
    with open(os.path.join(d, fn), "w", encoding="utf-8", errors="surrogateescape") as out:
        for s, p_ in sorted(rows, reverse=True): out.write(f"{s}\t{p_}\n")
report("GONE locally (deleted/moved/renamed since upload)", gone, "orphans-gone.tsv")
report("EXCLUDED now (still on disk, but skipped by exclude.txt / markers)", excluded, "orphans-excluded.tsv")
print(f"\nlists: {d}/orphans-gone.tsv and orphans-excluded.tsv (size<TAB>path, largest first)")
print("to delete: review a list, cut the path column into a file, then  backup.sh rclone delete --files-from-raw <file> <REMOTE>")
PYEOF
  lock_release
}

cmd_quota() {   # what the server says about the storage quota
  require rclone jq curl; state_init; setup_rclone || die "$KEYCHAIN_HINT"
  echo "-- rclone about $REMOTE_ROOT"; tmo 60 rclone --config "$RCLONE_CONF" about --json "$REMOTE_ROOT" 2>&1 | sed 's/^/   /'
  [[ -n "$REMOTE_OVERRIDE" ]] && return 0
  echo "-- raw PROPFIND for quota-available-bytes / quota-used-bytes on $WEBDAV_URL/"
  local var pw; var="RCLONE_CONFIG_${REMOTE_NAME^^}_PASS"; pw=$(rclone reveal "${!var}")
  printf 'user = "%s:%s"\n' "$WEBDAV_USER" "$pw" | curl -s --max-time 30 -K - -X PROPFIND -H 'Depth: 0' -H 'Content-Type: text/xml' \
      --data '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:quota-available-bytes/><D:quota-used-bytes/></D:prop></D:propfind>' "$WEBDAV_URL/" \
      | tr -d '\n' | sed 's/></>\n</g' | grep -iE 'quota|status' | sed 's/^/   /'
  unset pw
}

cmd_diag_keychain() {   # why can't the password be read? exit codes + timings only, the secret is never printed
  local tmp t0 spec kind svc; tmp=$(mktemp)
  echo "== keychain diagnostics  $(ts)  uid=$(id -u)  launchd session: $(launchctl managername 2>/dev/null || echo ?)"
  echo "-- security list-keychains"; security list-keychains 2>&1 | sed 's/^/   /'
  echo "-- show-keychain-info (login keychain; fails with 'User interaction is not allowed' when locked without UI)"
  security show-keychain-info 2>&1 | sed 's/^/   /'
  for spec in "generic:$KEYCHAIN_SERVICE" "internet:$KEYCHAIN_FALLBACK_SERVER"; do
    kind=${spec%%:*}; svc=${spec#*:}; [[ -n "$svc" ]] || continue
    echo "-- find-$kind-password -s '$svc' -a '$WEBDAV_USER'  (attributes only)"
    t0=$(now); security "find-$kind-password" -s "$svc" -a "$WEBDAV_USER" >/dev/null 2>"$tmp"; echo "   exit $?  ($(( $(now) - t0 ))s)  $(tr '\n' ' ' < "$tmp")"
    echo "-- same with -w  (secret discarded; exit 124 = waited 45s for a dialog nobody clicked, 36 = keychain locked/no UI, 44 = not found)"
    t0=$(now); tmo 45 security "find-$kind-password" -s "$svc" -a "$WEBDAV_USER" -w >/dev/null 2>"$tmp"; echo "   exit $?  ($(( $(now) - t0 ))s)  $(tr '\n' ' ' < "$tmp")"
  done
  rm -f "$tmp"
}

cmd_retire_old() {   # disable the old duck-based mechanism; everything is moved into old/, nothing is deleted
  local yes=0; [[ "${1:-}" == --yes ]] && yes=1
  local uid old l f a; uid=$(id -u); old="$SCRIPT_DIR/old"
  local -a labels=(com.backup.duck com.example.duck)
  echo "This retires the old duck backup:"
  echo "  - unload + move  ~/Library/LaunchAgents/{${labels[0]},${labels[1]}}.plist  → $old/"
  echo "  - move           ~/.backup_script.sh, ~/.backup.log (+ ~/.tmp if it is the old log copy)  → $old/"
  echo "  - crontab:       remove the 'duck --sync' line (full copy kept in $old/crontab.before)"
  if (( ! yes )); then read -r -p "proceed? [y/N] " a; [[ "$a" == y || "$a" == Y ]] || { echo "aborted"; return 1; }; fi
  mkdir -p "$old"
  for l in "${labels[@]}"; do
    f="$HOME/Library/LaunchAgents/$l.plist"
    launchctl bootout "gui/$uid/$l" 2>/dev/null && echo "unloaded $l"
    [[ -f "$f" ]] && mv "$f" "$old/" && echo "moved    $f"
  done
  [[ -f "$HOME/.backup_script.sh" ]] && mv "$HOME/.backup_script.sh" "$old/" && echo "moved    ~/.backup_script.sh"
  [[ -f "$HOME/.backup.log" ]] && mv "$HOME/.backup.log" "$old/backup.log" && echo "moved    ~/.backup.log"
  [[ -f "$HOME/.tmp" ]] && grep -q 'duck --sync' "$HOME/.tmp" && mv "$HOME/.tmp" "$old/backup.log.partial" && echo "moved    ~/.tmp (old log copy)"
  if crontab -l >/dev/null 2>&1; then
    crontab -l > "$old/crontab.before"
    if grep -q 'duck --sync' "$old/crontab.before"; then grep -v 'duck --sync' "$old/crontab.before" | crontab - && echo "crontab: duck line removed (backup: $old/crontab.before)"; fi
  fi
  echo "done. To undo: move the files back, 'launchctl bootstrap gui/$uid <plist>', and 'crontab $old/crontab.before'."
}

cmd_rclone() { require rclone; state_init; setup_rclone || die "$KEYCHAIN_HINT"; exec rclone --config "$RCLONE_CONF" "$@"; }

# ----------------------------------------------------------------------------- dispatch
case "${1:-help}" in
  tick)      shift; cmd_tick "$@" ;;
  run)       shift; cmd_run "$@" ;;
  check)     shift; cmd_check "$@" ;;
  status)    cmd_status ;;
  log)       shift; cmd_log "$@" ;;
  setup)     cmd_setup ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  pause)     state_init; state_set paused 1; echo "scheduled runs paused (backup.sh resume to continue)" ;;
  resume)    state_init; state_set paused 0; echo "scheduled runs resumed" ;;
  gui-run)   shift; cmd_gui_run "$@" ;;
  probe)     cmd_probe ;;
  diag-keychain) cmd_diag_keychain ;;
  quota)     cmd_quota ;;
  orphans)   cmd_orphans ;;
  versions)  shift; cmd_versions "$@" ;;
  retire-old) shift; cmd_retire_old "$@" ;;
  rclone)    shift; cmd_rclone "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
