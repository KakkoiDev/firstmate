#!/usr/bin/env bash
# tests/fm-todo-guard.test.sh - open notes-keeping todos that no work owns are
# named wherever a todo note is drained or acknowledged and on every heartbeat,
# and acknowledging a todo note that still has one refuses without an explicit
# --no-dispatch reason.
#
# The notes-keeping bridge is a stand-in at config/notes-keeping-bridge that
# answers `status` from a JSON file in the home and logs `link` calls, which is
# the bridge's documented verb contract; the plugin itself is not under test.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-todo-guard)

make_home() {  # <name> -> home with a stand-in bridge and one todo notes file
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state/inbox/handled" "$home/data" "$home/config"
  cat > "$home/config/notes-keeping-bridge" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) cat "$FM_HOME/bridge-status.json" ;;
  link) shift; printf '%s\t%s\n' "$1" "$2" >> "$FM_HOME/bridge-links.log" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$home/config/notes-keeping-bridge"
  cat > "$home/notes.md" <<'EOF'
# Objectives

# Todo

- [ ] write the release note
- [~] **Fix login**: fix the login redirect
- [ ] Ship   the PARSER
- [ ] answer the vendor
- [x] old finished item
- [-] declined item

# Important

- [ ] not a todo, this is the Important section
EOF
  cat > "$home/bridge-status.json" <<'EOF'
{"fix the login redirect": {"status": "in-progress", "task": "login-fix"},
 "ship the parser": {"status": null, "task": "parser-gone"},
 "answer the vendor": {"status": null, "task": "vendor-held"}}
EOF
  printf '%s\n' "$home"
}

write_note() {  # <home> <id> <body>
  local home=$1 id=$2 body=$3
  printf 'id=%s\nat=2026-10-28T00:00:00Z\nsource=text\nannounce_marker=1\n--\n%s\n' "$id" "$body" \
    > "$home/state/inbox/$id.note"
}

todo_note() {  # <home> <id>
  write_note "$1" "$2" "write the release note (+1 more)
notes-keeping todo changed in $1/notes.md:
+ [ ] write the release note (captain)"
}

# A copy of the guard whose backlog lookup knows exactly the ids in
# <home>/backlog-ids, so ownership through the backlog is decided by the case.
iso_guard() {  # <home>
  local iso="$1/iso/bin"
  mkdir -p "$iso"
  cp "$ROOT/bin/fm-todo-guard.sh" "$iso/"
  cat > "$iso/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = show ] && grep -Fqx -- "$2" "$FM_HOME/backlog-ids"
SH
  chmod +x "$iso/fm-todo-guard.sh" "$iso/fm-tasks-axi.sh"
  : > "$1/backlog-ids"
  printf '%s\n' "$iso/fm-todo-guard.sh"
}

run_home() {  # <home> <command> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$@"
}

now_id() { printf '%s-%s' "$(date +%s)" "$1"; }

# --- the guard itself ------------------------------------------------------

home=$(make_home owned)
guard=$(iso_guard "$home")
printf 'vendor-held\n' > "$home/backlog-ids"
rc=0
out=$(run_home "$home" "$guard" unowned --notes "$home/notes.md") || rc=$?
expect_code 1 "$rc" "open unowned todos did not exit 1: $out"
assert_contains "$out" "UNOWNED TODOS" "no UNOWNED TODOS section was printed"
assert_contains "$out" "- [ ] write the release note  [$home/notes.md]" "an unlinked open todo was not listed"
assert_contains "$out" "- [ ] Ship   the PARSER (linked task parser-gone is gone)" \
  "a todo linked to a task that is gone was not listed"
assert_not_contains "$out" "login" "a todo linked to an in-progress task was listed"
assert_not_contains "$out" "vendor" "a todo whose task the backlog still has was listed"
assert_not_contains "$out" "finished" "a done todo was listed"
assert_not_contains "$out" "declined" "a declined todo was listed"
assert_not_contains "$out" "Important" "an item outside the Todo section was listed"
pass "unowned lists only open todos no live task or backlog item owns"

printf '{"write the release note": {"status": "done", "task": "rn"}, "ship the parser": {"status": "in-progress", "task": "p"}, "fix the login redirect": {"status": "in-progress", "task": "l"}, "answer the vendor": {"status": null, "task": "vendor-held"}}\n' \
  > "$home/bridge-status.json"
rc=0
out=$(run_home "$home" "$guard" unowned --notes "$home/notes.md") || rc=$?
expect_code 0 "$rc" "a fully owned list did not exit 0: $out"
assert_equals "" "$out" "a fully owned list printed something"
pass "unowned is silent when every open todo is owned"

home=$(make_home no-bridge)
guard=$(iso_guard "$home")
rm "$home/config/notes-keeping-bridge"
rc=0
out=$(run_home "$home" "$guard" unowned --notes "$home/notes.md") || rc=$?
expect_code 0 "$rc" "a home without the bridge did not exit 0"
assert_equals "" "$out" "a home without the bridge printed something"
pass "unowned does nothing when config/notes-keeping-bridge is absent"

home=$(make_home recent)
guard=$(iso_guard "$home")
todo_note "$home" "$(now_id aaaaaa)"
write_note "$home" "1000000000-old" "notes-keeping todo changed in $home/old-notes.md:"
printf '# Todo\n- [ ] stale file item\n' > "$home/old-notes.md"
rc=0
out=$(run_home "$home" "$guard" unowned) || rc=$?
expect_code 1 "$rc" "the recent notes file was not checked: $out"
assert_contains "$out" "write the release note" "the file a recent todo note names was not read"
assert_not_contains "$out" "stale file item" "a file named only by an old note was read"
pass "unowned with no arguments reads the files recent todo notes name"

# --- inbox drain and acknowledgement ---------------------------------------

home=$(make_home inbox)
id=$(now_id bbbbbb)
todo_note "$home" "$id"
write_note "$home" "$(now_id cccccc)" "an ordinary captain note"
out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain) || fail "drain failed: $out"
assert_contains "$out" "UNOWNED TODOS" "draining a todo note did not print UNOWNED TODOS"
assert_contains "$out" "write the release note  [$home/notes.md]" "drain did not list the unowned todo"
pass "drain prints UNOWNED TODOS when a pending note is a todo note"

rc=0
out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" 2>&1) || rc=$?
expect_code 1 "$rc" "acknowledging a todo note with an unowned todo did not refuse: $out"
assert_contains "$out" "UNOWNED TODOS" "the refusal did not list the unowned todos"
assert_contains "$out" "--no-dispatch" "the refusal did not name the override"
[ -f "$home/state/inbox/$id.note" ] || fail "a refused acknowledgement moved the note"
pass "acknowledging a todo note with an unowned todo refuses and keeps the note pending"

out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" --no-dispatch "captain is doing it by hand") \
  || fail "--no-dispatch did not acknowledge: $out"
assert_contains "$out" "acked $id" "--no-dispatch did not report the acknowledgement"
[ -f "$home/state/inbox/handled/$id.note" ] || fail "--no-dispatch did not move the note to handled"
grep -F "$id	captain is doing it by hand" "$home/state/inbox/.no-dispatch.log" >/dev/null \
  || fail "--no-dispatch did not record its reason"
pass "--no-dispatch acknowledges the note and records why nothing was dispatched"

other=$(now_id dddddd)
write_note "$home" "$other" "an ordinary captain note"
out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$other") || fail "ordinary ack refused: $out"
assert_contains "$out" "acked $other" "an ordinary note was not acknowledged"
pass "acknowledging a note that is not a todo note is unchanged"

rc=0
out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$other" --no-dispatch "" 2>&1) || rc=$?
expect_code 1 "$rc" "an empty --no-dispatch reason was accepted"
pass "--no-dispatch needs a non-empty reason"

home=$(make_home owned-ack)
id=$(now_id eeeeee)
todo_note "$home" "$id"
printf '{"write the release note": {"status": "in-progress", "task": "rn"}, "ship the parser": {"status": "in-progress", "task": "p"}, "answer the vendor": {"status": "done", "task": "v"}, "fix the login redirect": {"status": "in-progress", "task": "l"}}\n' \
  > "$home/bridge-status.json"
out=$(run_home "$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$id") || fail "an owned todo note was refused: $out"
assert_contains "$out" "acked $id" "a todo note whose todos are all owned was not acknowledged"
pass "a todo note whose open todos are all owned acknowledges without --no-dispatch"

# --- heartbeat -------------------------------------------------------------

home=$(make_home heartbeat)
todo_note "$home" "$(now_id ffffff)"
fm_test_track_watcher_state "$home/state"
: > "$home/config/supervision-host-off"
# shellcheck disable=SC2016 # expanded by the appending shell
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat fleet "heartbeat review"' _ "$ROOT" \
  || fail "could not queue a heartbeat"
out=$(run_home "$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) || true
assert_contains "$out" "UNOWNED TODOS" "a heartbeat drain did not print UNOWNED TODOS"
assert_contains "$out" "write the release note" "a heartbeat drain did not list the unowned todo"
pass "a heartbeat drain prints UNOWNED TODOS"

home=$(make_home signal-only)
todo_note "$home" "$(now_id gggggg)"
fm_test_track_watcher_state "$home/state"
: > "$home/config/supervision-host-off"
# shellcheck disable=SC2016 # expanded by the appending shell
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check other "some check"' _ "$ROOT" \
  || fail "could not queue a check"
out=$(run_home "$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) || true
assert_not_contains "$out" "UNOWNED TODOS" "a drain with no heartbeat printed UNOWNED TODOS"
pass "a drain without a heartbeat leaves UNOWNED TODOS to the heartbeat"

home=$(make_home heartbeat-release)
fm_test_track_watcher_state "$home/state"
: > "$home/config/supervision-host-off"
fakebin=$(fm_fakebin "$home")
fm_fake_exit0 "$fakebin" tmux treehouse gh gh-axi
fm_write_meta "$home/state/finished-scout.meta" "kind=scout" "window=fake:fm-finished-scout" \
  "endpoint_task_id=finished-scout" "worktree=$home/absent-copy" "project=$home/absent-project" "harness=codex"
printf 'done [at=2]: report written\n' > "$home/state/finished-scout.status"
mkdir -p "$home/data/finished-scout"
printf '# report\n' > "$home/data/finished-scout/report.md"
# shellcheck disable=SC2016 # expanded by the appending shell
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat fleet "heartbeat review"' _ "$ROOT" \
  || fail "could not queue a heartbeat"
out=$(PATH="$fakebin:$PATH" run_home "$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null) || true
assert_contains "$out" "AUTO-RELEASE" "a heartbeat drain did not run the cleanup sweep"
assert_contains "$out" "finished-scout (report done)" "the heartbeat sweep did not act on the finished scout"
pass "a heartbeat drain cleans up finished workers and reports each in one line"
