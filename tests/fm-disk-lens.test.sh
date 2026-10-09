#!/usr/bin/env bash
# tests/fm-disk-lens.test.sh - disk-lens safety rules and the scan JSON mode.
#
# Every action runs against throwaway fixtures under a temp HOME: git repos with
# a local bare remote reached through a github.com URL rewritten by insteadOf,
# temp files, and a sleep process. PATH fakes stand in for trash, osascript,
# docker, treehouse, and claude, so nothing real is trashed or removed.
#
# Covers: loopback-only bind, the per-launch token on page and API, the Host
# guard, confirm required; worktree removal refused when dirty, without a
# GitHub remote, when a live task owns it, or when the push fails, and the
# clean path pushing without force, logging, and mirroring the log to a
# separate repo without touching that checkout's files or index; Trash only
# through the trash tool (contents survive in the fake trash bin) with an
# honest failure when Trash is unavailable; SIGKILL only after SIGTERM and a
# warning gate on the server's own process; the --scan-json report.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-disk-lens)
SRV_PID=""
SLEEP_PID=""
on_exit() {
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null || true
  [ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap on_exit EXIT

fm_git_identity
H="$TMP_ROOT/home"
FMH="$TMP_ROOT/fmhome"
REMOTES="$TMP_ROOT/remotes"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$H/Code" "$FMH/state" "$FMH/data" "$FMH/config" "$REMOTES" "$TMP_ROOT/trashbin"
GITCONFIG="$TMP_ROOT/gitconfig"
: >"$GITCONFIG"

cat >"$FAKEBIN/trash" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$TMP_ROOT/trash.log"
case "\$1" in *stuff-locked*) exit 1 ;; esac
mv "\$1" "$TMP_ROOT/trashbin/"
SH
for tool in osascript docker treehouse claude; do
  printf '#!/usr/bin/env bash\necho "%s unavailable in tests" >&2\nexit 1\n' "$tool" >"$FAKEBIN/$tool"
done
chmod +x "$FAKEBIN"/*

srv_env() {
  env HOME="$H" PATH="$FAKEBIN:$PATH" GIT_CONFIG_GLOBAL="$GITCONFIG" GIT_CONFIG_NOSYSTEM=1 \
    TREEHOUSE_ROOT="$H/.treehouse" "$@"
}

# --- fixtures -----------------------------------------------------------------

# github_repo <name> <dir>: a repo at <dir> whose origin is https://github.com/fmtest/<name>.git,
# rewritten to a local bare remote.
github_repo() {
  local name=$1 dir=$2
  fm_git_init_commit "$dir"
  git clone --quiet --bare "$dir" "$REMOTES/$name.git"
  git -C "$dir" remote add origin "https://github.com/fmtest/$name.git"
  printf '[url "file://%s"]\n\tinsteadOf = https://github.com/fmtest/%s.git\n' "$REMOTES/$name.git" "$name" >>"$GITCONFIG"
  GIT_CONFIG_GLOBAL="$GITCONFIG" git -C "$dir" fetch --quiet origin
}

commit_in() {
  local dir=$1 msg=$2
  printf '%s\n' "$msg" >"$dir/$msg.txt"
  git -C "$dir" add "$msg.txt"
  git -C "$dir" commit --quiet -m "$msg"
}

github_repo proj "$H/Code/proj"
for b in clean dirty owned diverged; do
  git -C "$H/Code/proj" worktree add --quiet -b "feat-$b" "$H/wt/$b"
  commit_in "$H/wt/$b" "work-$b"
done
printf 'scratch\n' >"$H/wt/dirty/untracked.txt"
fm_write_meta "$FMH/state/live-task.meta" "worktree=$H/wt/owned" "kind=ship"
# The remote already holds a different feat-diverged, so a no-force push is rejected.
git --git-dir="$REMOTES/proj.git" branch feat-diverged main
other=$(git --git-dir="$REMOTES/proj.git" commit-tree -p main -m other "$(git --git-dir="$REMOTES/proj.git" rev-parse 'main^{tree}')")
git --git-dir="$REMOTES/proj.git" update-ref refs/heads/feat-diverged "$other"

fm_git_init_commit "$H/Code/localonly"
git -C "$H/Code/localonly" worktree add --quiet -b feat-local "$H/wt/local"
commit_in "$H/wt/local" work-local

# Log mirror: a separate repo whose checkout carries staged and untracked
# changes that the mirror must leave alone.
fm_git_init_commit "$TMP_ROOT/dotseed"
git -C "$TMP_ROOT/dotseed" branch -m master
git clone --quiet --bare "$TMP_ROOT/dotseed" "$REMOTES/dot.git"
git clone --quiet "$REMOTES/dot.git" "$H/dotfiles"
printf 'plugin sync\n' >"$H/dotfiles/untracked-sync.txt"
printf 'staged edit\n' >>"$H/dotfiles/README.md"
git -C "$H/dotfiles" add README.md
printf 'repo=%s\n' "$H/dotfiles" >"$FMH/config/disk-lens-log-repo"
dot_status_before=$(git -C "$H/dotfiles" status --porcelain)
dot_head_before=$(git -C "$H/dotfiles" rev-parse HEAD)

mkdir -p "$H/stuff" "$H/stuff-locked"
dd if=/dev/zero of="$H/stuff/blob.bin" bs=1024 count=256 2>/dev/null
printf 'keep me\n' >"$H/stuff-locked/note.txt"

# --- scan JSON mode -----------------------------------------------------------

report=$(srv_env bash "$ROOT/bin/fm-disk-lens.sh" scan --tabs disk --top 200)
python3 - "$report" "$H" <<'PY' || fail "scan JSON report shape"
import json, sys
r = json.loads(sys.argv[1]); home = sys.argv[2]
assert r["volume"]["free"] > 0 and r["volume"]["total"] >= r["volume"]["free"]
assert r["measured"] is True
by_path = {i["path"]: i for i in r["items"]}
stuff = by_path[home + "/stuff"]
assert stuff["group"] == "personal" and stuff["action"] == "trash" and stuff["size"] >= 256 * 1024, stuff
wt = by_path[home + "/wt/clean"]
assert wt["kind"] == "worktree" and wt["action"] == "git-backup" and wt["details"]["branch"] == "feat-clean", wt
assert by_path[home + "/Code/proj"]["kind"] == "repo"
assert any(k.startswith("disk/") for k in r["groups"])
PY
pass "scan --tabs disk reports volume, groups, sized items, and git details"

report=$(srv_env bash "$ROOT/bin/fm-disk-lens.sh" scan --tabs disk --no-du --top 200)
python3 - "$report" "$H" <<'PY' || fail "scan --no-du skips sizing"
import json, sys
r = json.loads(sys.argv[1])
assert r["measured"] is False
assert all(i["size"] is None for i in r["items"] if i["kind"] == "path"), r["items"]
PY
pass "scan --no-du lists items without running du"

set +e
srv_env bash "$ROOT/bin/fm-disk-lens.sh" scan --tabs bogus >/dev/null 2>&1
rc=$?
set -e
assert_equals 2 "$rc" "scan rejects an unknown tab"
pass "scan rejects an unknown tab"

# --- bind and token -----------------------------------------------------------

TOK="$TMP_ROOT/token"
python3 -c 'import secrets; print(secrets.token_hex(32))' >"$TOK"
# Bounded: a regression that starts listening must fail here, not hang.
(exec env HOME="$H" PATH="$FAKEBIN:$PATH" python3 "$ROOT/bin/fm-disk-lens.py" --home "$FMH" \
  --token-file "$TOK" --bind 0.0.0.0 >/dev/null 2>"$TMP_ROOT/bind.err") &
bind_pid=$!
for _ in $(seq 1 100); do kill -0 "$bind_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$bind_pid" 2>/dev/null; then
  kill "$bind_pid"
  fail "server with --bind 0.0.0.0 kept running"
fi
set +e
wait "$bind_pid"
rc=$?
set -e
assert_equals 2 "$rc" "non-loopback bind exits 2"
assert_grep 'refusing to bind 0.0.0.0' "$TMP_ROOT/bind.err" "expected refusing to bind 0.0.0.0"
printf 'short\n' >"$TMP_ROOT/short-token"
set +e
srv_env python3 "$ROOT/bin/fm-disk-lens.py" --home "$FMH" --token-file "$TMP_ROOT/short-token" >/dev/null 2>&1
rc=$?
set -e
assert_equals 2 "$rc" "a short token is refused"
pass "server refuses a non-loopback bind and a weak token"

URLF="$TMP_ROOT/url"
# exec keeps $! on the server itself rather than a wrapping subshell.
(exec env HOME="$H" PATH="$FAKEBIN:$PATH" GIT_CONFIG_GLOBAL="$GITCONFIG" GIT_CONFIG_NOSYSTEM=1 \
  TREEHOUSE_ROOT="$H/.treehouse" python3 "$ROOT/bin/fm-disk-lens.py" --home "$FMH" --token-file "$TOK" \
  --url-file "$URLF" --idle-minutes 10 >"$TMP_ROOT/server.log" 2>&1) &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$URLF" ] && break; sleep 0.1; done
[ -s "$URLF" ] || fail "server never wrote its URL: $(cat "$TMP_ROOT/server.log")"
T=$(cat "$TOK")
PORT=$(sed -E 's#^http://127\.0\.0\.1:([0-9]+)/.*#\1#' "$URLF")
assert_grep "listening on 127.0.0.1:$PORT" "$TMP_ROOT/server.log" "expected listening on 127.0.0.1:PORT"
if command -v lsof >/dev/null 2>&1; then
  listen=$(lsof -nP -a -p "$SRV_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true)
  assert_contains "$listen" "127.0.0.1:$PORT" "listener is bound to loopback"
  assert_not_contains "$listen" "*:$PORT" "listener is not bound to every interface"
fi
pass "server listens on 127.0.0.1 only"

BASE="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
assert_equals 403 "$(code "$BASE/api/items?tab=disk")" "API without token"
assert_equals 403 "$(code -H "X-Disk-Lens-Token: ${T%?}x" "$BASE/api/items?tab=disk")" "API with wrong token"
assert_equals 403 "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/rescan")" "POST without token"
assert_equals 403 "$(code "$BASE/")" "page without token"
assert_equals 200 "$(code "$BASE/?token=$T")" "page with token"
assert_equals 403 "$(code -H "Host: evil.example:$PORT" -H "X-Disk-Lens-Token: $T" "$BASE/api/items")" "foreign Host"
assert_equals 403 "$(code -H "Origin: http://evil.example" -H "X-Disk-Lens-Token: $T" -X POST -d '{}' "$BASE/api/rescan")" "foreign Origin"
pass "token required on page and every API call; foreign Host and Origin refused"

# api <path> [json] -> body on stdout, status in $TMP_ROOT/status
api() {
  local path=$1 body=${2:-}
  if [ -n "$body" ]; then
    curl -s -o "$TMP_ROOT/body" -w '%{http_code}' -H "X-Disk-Lens-Token: $T" -H 'Content-Type: application/json' -d "$body" "$BASE$path" >"$TMP_ROOT/status"
  else
    curl -s -o "$TMP_ROOT/body" -w '%{http_code}' -H "X-Disk-Lens-Token: $T" "$BASE$path" >"$TMP_ROOT/status"
  fi
  cat "$TMP_ROOT/body"
}
status() { cat "$TMP_ROOT/status"; }

for _ in $(seq 1 300); do
  api "/api/items?tab=disk" | python3 -c 'import json,sys; sys.exit(0 if not json.load(sys.stdin)["scanning"] else 1)' && break
  sleep 0.2
done
id_of() {  # <tab> <path>
  api "/api/items?tab=$1" | python3 -c '
import json, sys
for i in json.load(sys.stdin)["items"]:
    if i["path"] == sys.argv[1]:
        print(i["id"]); break
else:
    sys.exit("no item for " + sys.argv[1])' "$2"
}
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1], {"d": d})))' "$1"; }

# --- confirm required ---------------------------------------------------------

clean_id=$(id_of disk "$H/wt/clean")
api /api/free "{\"id\":\"$clean_id\"}" >/dev/null
assert_equals 400 "$(status)" "free without confirm"
[ -d "$H/wt/clean" ] || fail "free without confirm removed the worktree"
pass "free needs an explicit confirm"

# --- refusals -----------------------------------------------------------------

refuse_case() {  # <path> <expected refusal fragment> <label>
  local id out
  id=$(id_of disk "$1")
  out=$(api /api/preview "{\"id\":\"$id\"}")
  assert_contains "$(printf '%s' "$out" | field 'd["refusals"]')" "$2" "$3 preview"
  out=$(api /api/free "{\"id\":\"$id\",\"confirm\":true}")
  assert_equals 409 "$(status)" "$3 free status"
  [ -d "$1" ] || fail "$3: refused free still removed $1"
  pass "refuses $3"
}
refuse_case "$H/wt/dirty" "uncommitted or untracked changes" "a dirty worktree"
refuse_case "$H/wt/local" "no GitHub remote" "a worktree whose repo has no GitHub remote"
refuse_case "$H/wt/owned" "live firstmate task live-task" "a worktree a live task owns"
[ -z "$(git --git-dir="$REMOTES/proj.git" for-each-ref refs/heads/feat-dirty refs/heads/feat-owned)" ] ||
  fail "a refused free still pushed a branch"

div_id=$(id_of disk "$H/wt/diverged")
before=$(git --git-dir="$REMOTES/proj.git" rev-parse refs/heads/feat-diverged)
out=$(api /api/free "{\"id\":\"$div_id\",\"confirm\":true}")
assert_equals 502 "$(status)" "rejected push: $out"
assert_contains "$out" "push of feat-diverged" "push failure is reported"
[ -d "$H/wt/diverged" ] || fail "worktree removed after a failed push"
assert_equals "$before" "$(git --git-dir="$REMOTES/proj.git" rev-parse refs/heads/feat-diverged)" "remote branch was not forced"
pass "refuses removal when the push fails, and never forces"

# --- clean path: push, log, mirror, remove ------------------------------------

out=$(api /api/free "{\"id\":\"$clean_id\",\"confirm\":true}")
assert_equals 200 "$(status)" "clean worktree free: $out"
[ ! -e "$H/wt/clean" ] || fail "clean worktree still exists"
git -C "$H/Code/proj" worktree list --porcelain | grep -q "$H/wt/clean" && fail "worktree record survived"
assert_equals "$(git -C "$H/Code/proj" rev-parse refs/heads/feat-clean)" \
  "$(git --git-dir="$REMOTES/proj.git" rev-parse refs/heads/feat-clean)" "branch pushed to the GitHub remote"
assert_contains "$out" "https://github.com/fmtest/proj/tree/feat-clean" "pushed URL reported"
LOG="$FMH/data/disk-lens/backup-log.md"
assert_grep "$H/wt/clean" "$LOG" "backup log names the removed worktree"
assert_grep "branch feat-clean: pushed to origin/feat-clean" "$LOG" "expected branch feat-clean: pushed to origin/feat-clean"
assert_grep "repo: fmtest/proj" "$LOG" "expected repo: fmtest/proj"
assert_grep "work-clean" "$LOG" "expected work-clean"
assert_grep "summary: 1 commit(s) not on origin/" "$LOG" "expected summary: 1 commit(s) not on origin/"
pass "clean worktree: branch pushed, entry logged, worktree removed"

mirror_files=$(git --git-dir="$REMOTES/dot.git" show --name-only --format= master)
assert_equals "firstmate/disk-lens-backup-log.md" "$mirror_files" "mirror commit touches only the log file"
git --git-dir="$REMOTES/dot.git" show master:firstmate/disk-lens-backup-log.md >"$TMP_ROOT/mirror.md"
assert_grep "branch feat-clean: pushed to origin/feat-clean" "$TMP_ROOT/mirror.md" "expected branch feat-clean: pushed to origin/feat-clean"
assert_equals "$dot_status_before" "$(git -C "$H/dotfiles" status --porcelain)" "mirror left the checkout's files and index alone"
assert_equals "$dot_head_before" "$(git -C "$H/dotfiles" rev-parse HEAD)" "mirror left the checkout's HEAD alone"
pass "log mirror commits and pushes only its file, leaving the checkout untouched"

# --- Trash --------------------------------------------------------------------

stuff_id=$(id_of disk "$H/stuff")
assert_contains "$(api /api/preview "{\"id\":\"$stuff_id\"}" | field 'd["steps"]')" "macOS Trash" "trash preview"
api /api/free "{\"id\":\"$stuff_id\",\"confirm\":true}" >/dev/null
assert_equals 200 "$(status)" "trash free"
[ ! -e "$H/stuff" ] || fail "trashed path still in place"
assert_grep "$H/stuff" "$TMP_ROOT/trash.log" "trash tool received the path"
[ -f "$TMP_ROOT/trashbin/stuff/blob.bin" ] || fail "trashed contents did not reach the trash bin"
pass "personal path goes through the trash tool, contents preserved"

locked_id=$(id_of disk "$H/stuff-locked")
out=$(api /api/free "{\"id\":\"$locked_id\",\"confirm\":true}")
assert_equals 502 "$(status)" "trash failure"
assert_contains "$out" "could not move to Trash" "trash failure reported"
[ -f "$H/stuff-locked/note.txt" ] || fail "failed trash deleted the file"
pass "when Trash fails the path is left in place, never removed another way"

# --- kill ---------------------------------------------------------------------

sleep 300 &
SLEEP_PID=$!
lstart=$(api /api/procs | python3 -c '
import json, sys
for p in json.load(sys.stdin)["procs"]:
    if p["pid"] == int(sys.argv[1]):
        print(p["lstart"]); break' "$SLEEP_PID")
[ -n "$lstart" ] || fail "fixture sleep not listed"
api /api/kill "{\"pid\":$SLEEP_PID,\"lstart\":\"$lstart\",\"signal\":\"KILL\",\"ack_warning\":true}" >/dev/null
assert_equals 409 "$(status)" "SIGKILL before SIGTERM"
kill -0 "$SLEEP_PID" || fail "SIGKILL was sent without SIGTERM"
api /api/kill "{\"pid\":$SLEEP_PID,\"lstart\":\"Mon Jan 1 00:00:00 2001\",\"signal\":\"TERM\",\"ack_warning\":true}" >/dev/null
assert_equals 409 "$(status)" "stale process identity"
out=$(api /api/kill "{\"pid\":$SLEEP_PID,\"lstart\":\"$lstart\",\"signal\":\"TERM\",\"ack_warning\":true}")
assert_equals 200 "$(status)" "SIGTERM: $out"
wait "$SLEEP_PID" 2>/dev/null || true
kill -0 "$SLEEP_PID" 2>/dev/null && fail "fixture sleep survived SIGTERM"
SLEEP_PID=""
pass "SIGKILL needs a prior SIGTERM; a reused pid is refused; SIGTERM ends the fixture"

srv_lstart=$(api /api/procs | python3 -c '
import json, sys
for p in json.load(sys.stdin)["procs"]:
    if p["pid"] == int(sys.argv[1]):
        print(p["lstart"]); break' "$SRV_PID")
out=$(api /api/kill "{\"pid\":$SRV_PID,\"lstart\":\"$srv_lstart\",\"signal\":\"TERM\"}")
assert_equals 409 "$(status)" "own process without acknowledgement"
assert_contains "$out" "this is disk-lens itself" "own-process warning"
kill -0 "$SRV_PID" || fail "server was signalled without acknowledgement"
pass "killing disk-lens itself needs the warning acknowledged"

# --- quit ---------------------------------------------------------------------

api /api/quit '{}' >/dev/null
for _ in $(seq 1 50); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$SRV_PID" 2>/dev/null && fail "server still running after quit"
SRV_PID=""
pass "Quit stops the server"
