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

# --- a task closed with no worker ------------------------------------------

# The ChatGPT chain: a scout whose report left work records outcome `open`,
# firstmate holds the follow-up that report asked for (linked to the report),
# and the captain's answer closes that follow-up with no worker and no cleanup.
if command -v tasks-axi >/dev/null 2>&1; then
  closed_home() {  # <name> -> home with a real markdown backlog and the chain's links
    local home
    home=$(make_home "$1")
    fm_test_tasks_toml "$home/.tasks.toml"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
    mkdir -p "$home/data/chatgpt-it-reply"
    printf '# report\n' > "$home/data/chatgpt-it-reply/report.md"
    cat > "$home/state/notes-todo-links.jsonl" <<JSON
{"task": "chatgpt-it-reply", "key": "id:1kupnl3", "id": "1kupnl3", "by": "firstmate", "at": 100}
{"task": "chatgpt-it-reply", "outcome": "open", "at": 200, "kind": "scout", "report": "$home/data/chatgpt-it-reply/report.md"}
{"task": "chatgpt-login-retry", "key": "id:06ie42j", "id": "06ie42j", "by": "firstmate", "at": 300}
JSON
    printf '{"id:1kupnl3": {"status": null, "task": "chatgpt-it-reply", "id": "1kupnl3"}, "id:06ie42j": {"status": "in-progress", "task": "chatgpt-login-retry", "id": "06ie42j"}}\n' \
      > "$home/bridge-status.json"
    run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add chatgpt-login-retry "retry ChatGPT login" \
      --report data/chatgpt-it-reply/report.md >/dev/null || fail "could not add the follow-up"
    run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold chatgpt-login-retry --reason "captain retries login" >/dev/null \
      || fail "could not hold the follow-up"
    printf 'I successfully logged in ChatGPT\n' > "$home/decision.txt"
    printf '%s\n' "$home"
  }

  latest_outcome() {  # <home> <task> -> the task's latest outcome
    python3 - "$1/state/notes-todo-links.jsonl" "$2" <<'PY'
import json, sys
last = ''
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r.get('task') == sys.argv[2] and 'key' not in r and 'outcome' in r:
        last = r['outcome']
print(last)
PY
  }

  home=$(closed_home closed-release)
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer chatgpt-login-retry --decision-file "$home/decision.txt" --release >/dev/null \
    || fail "the release answer failed"
  run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" "done" chatgpt-login-retry >/dev/null || fail "done failed"
  assert_equals "done" "$(latest_outcome "$home" chatgpt-login-retry)" "a follow-up closed with no worker kept no done outcome"
  assert_equals "done" "$(latest_outcome "$home" chatgpt-it-reply)" "the scout's todo did not follow its finished follow-up"
  pass "a released hold marked done records its outcome and its scout's todo follows it"

  home=$(closed_home closed-answer)
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer chatgpt-login-retry --decision-file "$home/decision.txt" >/dev/null \
    || fail "the closing answer failed"
  assert_equals "done" "$(latest_outcome "$home" chatgpt-login-retry)" "a hold closed by its answer kept no done outcome"
  assert_equals "done" "$(latest_outcome "$home" chatgpt-it-reply)" "the scout's todo did not follow the answered follow-up"
  pass "a hold closed by the captain's answer records its outcome and its scout's todo follows it"

  home=$(closed_home closed-scout-itself)
  run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" add chatgpt-it-reply "read the IT reply" >/dev/null || fail "could not add the scout row"
  run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" "done" chatgpt-it-reply >/dev/null || fail "done failed"
  assert_equals open "$(latest_outcome "$home" chatgpt-it-reply)" "closing a cleaned-up scout's row overwrote its open outcome"
  pass "closing a row whose cleanup already recorded an outcome leaves that outcome"

  home=$(closed_home closed-live)
  fm_write_meta "$home/state/chatgpt-login-retry.meta" "kind=ship" "window=fake:fm-x"
  run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" "done" chatgpt-login-retry >/dev/null || fail "done failed"
  assert_equals '' "$(latest_outcome "$home" chatgpt-login-retry)" "a task with a live worker got an outcome before its cleanup"
  assert_equals open "$(latest_outcome "$home" chatgpt-it-reply)" "a scout's todo followed a follow-up whose worker is still live"
  pass "a task with a live worker leaves its outcome to cleanup"

  # The RBAC chain: the scout's report raised a captain call, held with
  # --origin and --report while the scout still owned its todo, so the todo
  # stays linked to the scout and the hold carries no `report:` link.
  home=$(make_home closed-hold-report)
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  mkdir -p "$home/data/rbac-migrate"
  printf '# report\n' > "$home/data/rbac-migrate/report.md"
  printf '{"task": "rbac-migrate", "key": "id:0xkvvot", "id": "0xkvvot", "by": "firstmate", "at": 100}\n' \
    > "$home/state/notes-todo-links.jsonl"
  printf '{"id:0xkvvot": {"status": "in-progress", "task": "rbac-migrate", "id": "0xkvvot"}}\n' > "$home/bridge-status.json"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold rbac-migrate-archive --title "Archive the old page?" \
    --reason "archive, keep, or point to the audit page?" --origin rbac-migrate \
    --report "$home/data/rbac-migrate/report.md" >/dev/null || fail "could not hold the scout's call"
  printf '{"task": "rbac-migrate", "outcome": "open", "at": 200, "kind": "scout", "report": "%s"}\n' \
    "$home/data/rbac-migrate/report.md" >> "$home/state/notes-todo-links.jsonl"
  printf 'keep it\n' > "$home/decision.txt"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer rbac-migrate-archive --decision-file "$home/decision.txt" >/dev/null \
    || fail "the closing answer failed"
  assert_equals "done" "$(latest_outcome "$home" rbac-migrate)" "the scout's todo stayed blocked after the answer closed its call"
  pass "an answer that closes a scout's call records the scout's todo done"

  # The promo chain: one captain call re-held from scout A's report to scout
  # B's, both scouts cleaned up with outcome `open`, then answered once.
  home=$(make_home closed-rehold-report)
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  mkdir -p "$home/data/promo-a" "$home/data/promo-b"
  printf '# report\n' > "$home/data/promo-a/report.md"
  printf '# report\n' > "$home/data/promo-b/report.md"
  cat > "$home/state/notes-todo-links.jsonl" <<'JSON'
{"task": "promo-a", "key": "id:aaaaaaa", "id": "aaaaaaa", "by": "firstmate", "at": 100}
{"task": "promo-b", "key": "id:bbbbbbb", "id": "bbbbbbb", "by": "firstmate", "at": 100}
JSON
  printf '{"id:aaaaaaa": {"status": "in-progress", "task": "promo-a", "id": "aaaaaaa"}, "id:bbbbbbb": {"status": "in-progress", "task": "promo-b", "id": "bbbbbbb"}}\n' \
    > "$home/bridge-status.json"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold promo-goals --title "Which goals can you answer?" \
    --reason "answer the open goal items" --origin promo-a --report "$home/data/promo-a/report.md" >/dev/null \
    || fail "could not hold scout A's call"
  printf '{"task": "promo-a", "outcome": "open", "at": 200, "kind": "scout", "report": "%s"}\n' \
    "$home/data/promo-a/report.md" >> "$home/state/notes-todo-links.jsonl"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold promo-goals --title "Which goals can you answer?" \
    --reason "answer the open goal items" --origin promo-b --report "$home/data/promo-b/report.md" >/dev/null \
    || fail "could not re-hold the call for scout B"
  printf '{"task": "promo-b", "outcome": "open", "at": 300, "kind": "scout", "report": "%s"}\n' \
    "$home/data/promo-b/report.md" >> "$home/state/notes-todo-links.jsonl"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold promo-goals --title "Which goals can you answer?" \
    --reason "answer the open goal items" --origin promo-b --report "$home/data/promo-b/report.md" >/dev/null \
    || fail "could not repeat the re-hold for scout B"
  body=$(run_home "$home" "$ROOT/bin/fm-tasks-axi.sh" show promo-goals --full) || fail "could not show the re-held call"
  assert_equals 1 "$(printf '%s\n' "$body" | grep -o 'Captain hold earlier report: [^\\]*promo-a/report.md' | wc -l | tr -d ' ')" \
    "a repeated re-hold did not keep scout A's report exactly once"
  assert_equals 0 "$(printf '%s\n' "$body" | grep -o 'Captain hold earlier report: [^\\]*promo-b/report.md' | wc -l | tr -d ' ')" \
    "the current report was also kept as an earlier one"
  printf 'goals 1 and 2\n' > "$home/decision.txt"
  run_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer promo-goals --decision-file "$home/decision.txt" >/dev/null \
    || fail "the closing answer failed"
  assert_equals "done" "$(latest_outcome "$home" promo-b)" "the latest scout's todo stayed blocked after the answer"
  assert_equals "done" "$(latest_outcome "$home" promo-a)" "an earlier scout's todo stayed blocked after a re-held call was answered"
  pass "an answer to a re-held call records every scout whose report it carried done"
else
  echo "skip: tasks-axi not found (the worker-less close cases need a real backlog)"
fi

# --- every task firstmate creates is linked to a todo ---------------------

# A stand-in bridge that also answers `active` and `update` the way the
# bridge's verb contract does: update prints the id of the todo it makes.
link_home() {  # <name> -> home with status, link, active and update
  local home
  home=$(make_home "$1")
  cat > "$home/config/notes-keeping-bridge" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) cat "$FM_HOME/bridge-status.json" ;;
  link) shift; printf '%s\t%s\n' "$1" "${*:2}" >> "$FM_HOME/bridge-links.log" ;;
  active) [ -e "$FM_HOME/bridge-active" ] || exit 1; cat "$FM_HOME/bridge-active" ;;
  update) shift; printf '%s\n' "$*" >> "$FM_HOME/bridge-updates.log"; echo 0aigen1 ;;
  *) exit 2 ;;
esac
SH
  printf '{}\n' > "$home/bridge-status.json"
  printf '%s\n' "$home"
}

home=$(link_home objective-ai)
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" objective sweep-1 "$home/notes.md" "Sweep stale branches" --ai-generated) \
  || fail "objective --ai-generated failed: $out"
assert_equals "0aigen1" "$out" "objective did not print the todo id"
assert_equals "$home/notes.md (AI-generated) sweep-1: Sweep stale branches --by firstmate --task sweep-1" \
  "$(cat "$home/bridge-updates.log")" "an AI-generated objective is not marked as one"
assert_equals "sweep-1	id:0aigen1 --by firstmate" "$(cat "$home/bridge-links.log")" "the objective's todo was not linked by id"
pass "objective --ai-generated marks the objective AI-generated and links its todo"

# A captain ask whose todo is already on the plugin's list links that item;
# an objective for it would queue a duplicate, so it is refused.
home=$(link_home objective-duplicate)
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" objective fix-1 "$home/notes.md" "Fix the login" 2>&1) || rc=$?
expect_code 1 "$rc" "an objective was queued while the captain's list has an unowned todo for it: $out"
assert_contains "$out" "- [~] Fix login" "the refusal did not list the captain's matching todo"
assert_not_contains "$out" "write the release note" "the refusal listed an unrelated todo"
assert_contains "$out" "--todo" "the refusal did not say to link the existing todo"
[ ! -e "$home/bridge-updates.log" ] || fail "a refused objective still queued an update"
pass "objective without --ai-generated refuses to duplicate an unowned todo that is this ask"

# Todos left unowned by unrelated work do not stop a new captain ask's todo.
home=$(link_home objective-unrelated)
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" objective nk-queue-split "$home/notes.md" "Split the NK queue into two lanes" 2>&1) \
  || fail "unrelated unowned todos refused a captain ask's objective: $out"
assert_equals "0aigen1" "$out" "objective did not print the todo id"
assert_equals "$home/notes.md nk-queue-split: Split the NK queue into two lanes --by firstmate --task nk-queue-split" \
  "$(cat "$home/bridge-updates.log")" "the captain ask's objective was not queued"
pass "objective without --ai-generated ignores unowned todos unrelated to the ask"

home=$(link_home objective-captain)
printf '# Todo\n\n- [x] old finished item\n' > "$home/notes.md"
run_home "$home" "$ROOT/bin/fm-todo-guard.sh" objective fix-1 "$home/notes.md" "Fix the login" >/dev/null \
  || fail "objective failed"
assert_equals "$home/notes.md fix-1: Fix the login --by firstmate --task fix-1" \
  "$(cat "$home/bridge-updates.log")" "an objective from a captain ask was marked or changed"
pass "objective without --ai-generated writes <task>: <text>"

# A captain hold blocked the todo linked to a task; once the hold is answered
# the todo can stay [!], and the task's own spawn must still resolve it.
home=$(link_home resolve-blocked)
printf '# Todo\n\n- [!] promo plan for H1 2027 <!-- id:0promo -->\n- [ ] answer the vendor\n' > "$home/notes.md"
printf '{"id:0promo": {"status": null, "task": "promo-h1-2027", "id": "0promo"}}\n' > "$home/bridge-status.json"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" resolve "promo plan" --task promo-h1-2027 --notes "$home/notes.md") \
  || fail "a blocked todo linked to the task did not resolve for it: $out"
assert_equals "promo plan for H1 2027 <!-- id:0promo -->" "$out" "resolve did not print the blocked todo linked to the task"
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" resolve "promo plan" --task other-task --notes "$home/notes.md") || rc=$?
expect_code 1 "$rc" "a blocked todo linked to another task resolved: $out"
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" resolve "promo plan" --notes "$home/notes.md") || rc=$?
expect_code 1 "$rc" "a blocked todo resolved without a task: $out"
pass "resolve --task accepts a blocked todo only when it is linked to that task"

home=$(link_home link-refuse)
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task held-1 2>&1) || rc=$?
expect_code 1 "$rc" "link-task with nothing to link did not refuse: $out"
assert_contains "$out" "held-1 has no notes-keeping todo linked" "the refusal did not say the task is unlinked"
assert_contains "$out" "--ai-generated" "the refusal did not name the AI-generated way"
[ ! -e "$home/bridge-links.log" ] || fail "a refused link-task linked something"
pass "link-task refuses a task it cannot link, naming what to pass"

home=$(link_home link-todo)
todo_note "$home" "$(now_id hhhhhh)"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task held-2 --todo "release note") || fail "link-task --todo failed: $out"
assert_equals "held-2	write the release note --by firstmate" "$(cat "$home/bridge-links.log")" "--todo did not link the resolved todo"
pass "link-task --todo links the one open todo it names"

home=$(link_home link-already)
printf '{"id:0abc": {"status": null, "task": "held-3", "id": "0abc"}}\n' > "$home/bridge-status.json"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task held-3) || fail "an already linked task was refused: $out"
assert_contains "$out" "linked held-3: id:0abc" "link-task did not report the existing link"
[ ! -e "$home/bridge-links.log" ] || fail "an already linked task was linked again"
pass "link-task passes a task the bridge already links"

# The ChatGPT chain: a scout's report left work, so its todos stay open with
# the scout gone; the follow-up held from it must carry those todos.
home=$(link_home link-origin)
printf '{"id:0yv2jqx": {"status": null, "task": "chatgpt-login", "id": "0yv2jqx"}, "id:1kupnl3": {"status": "in-progress", "task": "other-live", "id": "1kupnl3"}}\n' \
  > "$home/bridge-status.json"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task chatgpt-login-retry --origin chatgpt-login) \
  || fail "link-task --origin failed: $out"
assert_equals "chatgpt-login-retry	id:0yv2jqx --by firstmate" "$(cat "$home/bridge-links.log")" \
  "the follow-up did not take the todo its ended origin left open"
pass "link-task --origin moves an ended origin's open todo to the follow-up"

home=$(link_home link-origin-live)
printf '{"id:0live": {"status": "in-progress", "task": "ship-a", "id": "0live"}}\n' > "$home/bridge-status.json"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task ship-a-question --origin ship-a) \
  || fail "a hold from a live origin was refused: $out"
assert_contains "$out" "covered ship-a-question: id:0live (its origin ship-a still owns it)" "the live origin's cover was not reported"
[ ! -e "$home/bridge-links.log" ] || fail "a live origin's todo was moved away from it"
pass "link-task --origin leaves a live origin's todo with it and passes"

home=$(link_home link-objective)
printf '%s\n' "$home/notes.md" > "$home/bridge-active"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task sweep-2 --objective "Sweep stale branches" --ai-generated) \
  || fail "link-task --objective failed: $out"
assert_contains "$(cat "$home/bridge-updates.log")" "(AI-generated) sweep-2: Sweep stale branches" "the objective was not marked AI-generated"
assert_equals "sweep-2	id:0aigen1 --by firstmate" "$(cat "$home/bridge-links.log")" "the objective's todo was not linked"
pass "link-task --objective --ai-generated adds a marked objective and links it"

home=$(link_home link-no-todo)
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task maint-1 --no-todo "fleet maintenance") || fail "--no-todo without a session was refused: $out"
assert_contains "$out" "no todo maint-1: fleet maintenance" "--no-todo was not reported"
printf '%s\n' "$home/notes.md" > "$home/bridge-active"
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task maint-2 --no-todo "fleet maintenance" 2>&1) || rc=$?
expect_code 1 "$rc" "--no-todo was accepted while a notes session is active: $out"
pass "link-task --no-todo passes only while no notes-keeping session is active"

home=$(link_home link-contradict)
rc=0
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task x --ai-generated 2>&1) || rc=$?
expect_code 2 "$rc" "--ai-generated without --objective was accepted: $out"
pass "link-task --ai-generated needs an --objective"

home=$(link_home link-no-bridge)
rm "$home/config/notes-keeping-bridge"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" link-task x) || fail "link-task without a bridge refused: $out"
assert_equals "" "$out" "link-task without a bridge printed something"
pass "link-task does nothing when config/notes-keeping-bridge is absent"

# --- captain holds are linked before they are held -------------------------

if command -v tasks-axi >/dev/null 2>&1; then
  hold_home() {  # <name>
    local home
    home=$(link_home "$1")
    fm_test_tasks_toml "$home/.tasks.toml"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
    printf '%s\n' "$home"
  }
  hold() {  # <home> <args...>
    local home=$1
    shift
    run_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$@"
  }

  home=$(hold_home hold-refuse)
  rc=0
  out=$(hold "$home" call-1 --title "Pick the route" --reason "captain must decide" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlinked hold was created: $out"
  assert_contains "$out" "call-1 has no notes-keeping todo linked" "the hold refusal did not say why"
  if (cd "$home" && tasks-axi show call-1 >/dev/null 2>&1); then fail "a refused hold created its task"; fi
  pass "hold refuses, creating nothing, when the task links no todo"

  home=$(hold_home hold-origin)
  printf '{"id:0yv2jqx": {"status": null, "task": "chatgpt-login", "id": "0yv2jqx"}}\n' > "$home/bridge-status.json"
  out=$(hold "$home" chatgpt-login-retry --title "Log in to ChatGPT" --reason "captain must log in" --origin chatgpt-login) \
    || fail "a hold from an ended scout was refused: $out"
  assert_equals "chatgpt-login-retry	id:0yv2jqx --by firstmate" "$(cat "$home/bridge-links.log")" \
    "the held follow-up did not take its scout's open todo"
  pass "hold --origin moves the ended scout's open todo to the held follow-up"

  home=$(hold_home hold-ai)
  printf '%s\n' "$home/notes.md" > "$home/bridge-active"
  out=$(hold "$home" sweep-call --title "Sweep stale branches?" --reason "captain must approve" \
    --objective "Sweep stale branches?" --ai-generated) || fail "an AI-generated hold was refused: $out"
  assert_contains "$(cat "$home/bridge-updates.log")" "(AI-generated) sweep-call: Sweep stale branches?" \
    "the AI-generated hold's objective is not marked"
  (cd "$home" && tasks-axi show sweep-call >/dev/null 2>&1) || fail "the linked hold was not created"
  pass "hold --objective --ai-generated marks the objective and holds the task"
else
  echo "skip: tasks-axi not found; captain hold link cases not run"
fi

# --- related todos are named when a task's outcome is recorded -------------

home=$(link_home related)
cat > "$home/state/notes-todo-links.jsonl" <<'EOF'
{"task": "chatgpt-login", "key": "id:0yv2jqx", "id": "0yv2jqx", "at": 1}
{"task": "chatgpt-login-retry", "key": "id:0yv2jqx", "id": "0yv2jqx", "at": 2}
{"task": "pr-fix", "key": "id:0pr", "id": "0pr", "at": 3}
{"task": "pr-rereview", "outcome": "done", "at": 4, "pr": "https://github.com/o/r/pull/7"}
EOF
printf 'pr=https://github.com/o/r/pull/7\n' > "$home/state/pr-fix.meta"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" related chatgpt-login) || fail "related failed: $out"
assert_contains "$out" "RELATED TODOS" "related printed no section"
assert_contains "$out" "- chatgpt-login-retry: shares todo id:0yv2jqx (now linked to it)" "a follow-up sharing the todo was not named"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" related pr-fix) || fail "related failed: $out"
assert_contains "$out" "- pr-rereview: records the same PR https://github.com/o/r/pull/7" "a task on the same PR was not named"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" related lonely) || fail "related failed: $out"
assert_equals "" "$out" "related named something for a task with no relations"
printf 'done [at=5]: ok\n' > "$home/state/chatgpt-login-retry.status"
out=$(run_home "$home" "$ROOT/bin/fm-todo-guard.sh" record-outcome chatgpt-login-retry) || fail "record-outcome failed: $out"
assert_contains "$out" "- chatgpt-login: shares todo id:0yv2jqx" "record-outcome did not name the related task"
pass "related names tasks sharing a todo or a PR, and record-outcome prints it"
