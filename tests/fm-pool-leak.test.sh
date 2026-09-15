#!/usr/bin/env bash
# Behavior tests for the startup pool-slot leak check (bin/fm-pool-leak-lib.sh),
# exercised through the bootstrap detect path that prints its lines.
#
# The check answers one question per Treehouse pool slot: does the task whose
# claim holds this slot still have a worker? A slot held by a finished task is
# the leak that emptied a 16-slot pool on 2026-09-15, so every such slot must be
# named with the exact command that returns it - and nothing may be returned,
# reset, or re-claimed by the check itself, because a held slot can still carry
# work no branch holds.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-pool-leak)

unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# One pool with one slot, a project it is a worktree of, and a home that can
# hold task records. FM_FAKE_LIVE_TARGETS names the endpoints the fake tmux
# reports as present, so a case chooses liveness without racing real processes.
make_pool_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool/1"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" \
    > "$dir/pool/treehouse-state.json"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" gh gh-axi treehouse node tasks-axi quota-axi \
    lavish-axi no-mistakes chrome-devtools-axi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  for live in ${FM_FAKE_LIVE_TARGETS:-}; do
    [ "$live" != "${4:-}" ] || exit 0
  done
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

claim_slot() {  # <case> <task-id> <home>
  printf 'task=%s\nhome=%s\n' "$2" "$3" > "$1/pool/1/.fm-slot-owner"
}

run_detect() {  # <case> [live-target...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_FAKE_LIVE_TARGETS="$*" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_finished_task_still_holding_its_slot_is_named_with_its_cleanup_command() {
  local dir out id=finished-task
  dir=$(make_pool_case held-by-finished-task)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 is still held by task $id" \
    "a slot held by a task with no worker should be reported"
  assert_contains "$out" "FM_HOME=$dir/home $ROOT/bin/fm-teardown.sh $id" \
    "the report should print the exact command that returns the slot"
  # Detection only: the slot, its claim, and its copy are untouched.
  assert_present "$dir/pool/1/.fm-slot-owner" "the check removed a slot claim"
  assert_present "$dir/pool/1/project/.git" "the check removed a held slot's checkout"
  assert_present "$dir/home/state/$id.meta" "the check removed a task record"
  pass "pool leak: a slot still held by a finished task is named with its cleanup command"
}

test_slot_held_by_a_live_worker_is_silent() {
  local dir out id=live-task
  dir=$(make_pool_case held-by-live-worker)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "$id" "$dir/home"

  out=$(run_detect "$dir" "firstmate:fm-$id")
  assert_not_contains "$out" "POOL_LEAK:" \
    "a slot whose worker is still running is not a leak"
  pass "pool leak: a slot whose worker is still running reports nothing"
}

test_claim_with_no_record_and_an_unreadable_claim_are_reported_differently() {
  local dir out id=vanished-task
  dir=$(make_pool_case claim-without-record)
  claim_slot "$dir" "$id" "$dir/home"
  # Discovery runs over this home's records, so the neighbour record is what
  # keeps the pool discoverable once the claimant's own record is gone, and is
  # what makes this case reachable at all.
  mkdir -p "$dir/other/project"
  git -C "$dir/project" worktree add -q --detach "$dir/pool/2/project" 2>/dev/null \
    || mkdir -p "$dir/pool/2"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/2/project" "project=$dir/project" "kind=ship"

  out=$(run_detect "$dir" "firstmate:fm-neighbour")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 claims task $id" \
    "a claim whose home holds no record should be reported"
  assert_contains "$out" "no cleanup command can return that slot" \
    "the report should say why no cleanup command is offered"

  dir=$(make_pool_case unreadable-claim)
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  out=$(run_detect "$dir" "firstmate:fm-neighbour")
  assert_contains "$out" "$dir/pool/1/.fm-slot-owner" \
    "an unreadable claim should name the file to inspect"
  pass "pool leak: a claim with no record, and a claim that cannot be read, each report their own remediation"
}

test_unclaimed_slot_reports_nothing() {
  local dir out id=preclaim-task
  dir=$(make_pool_case unclaimed-slot)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"

  out=$(run_detect "$dir")
  assert_not_contains "$out" "POOL_LEAK:" \
    "an unclaimed slot has no claim to attribute and must not be reported"
  pass "pool leak: a slot carrying no claim reports nothing"
}


test_claim_with_no_home_is_reported_and_a_foreign_home_stays_silent() {
  local dir out id=homeless-task
  dir=$(make_pool_case claim-without-home)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  printf 'task=%s\nhome=\n' "$id" > "$dir/pool/1/.fm-slot-owner"

  out=$(run_detect "$dir")
  assert_contains "$out" "POOL_LEAK: $dir/pool slot 1 claims task $id" \
    "a claim naming a task but no home must still name the held slot"
  assert_contains "$out" "records no home" \
    "the report should say the claim carries no home"

  dir=$(make_pool_case claim-from-another-machine)
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=ship"
  claim_slot "$dir" "foreign-task" "$dir/absent-home"

  out=$(run_detect "$dir")
  assert_not_contains "$out" "POOL_LEAK:" \
    "a claim whose home does not exist here belongs to another machine and must stay silent"
  pass "pool leak: a claim with no home is reported, a claim from a home absent here is not"
}

test_finished_task_still_holding_its_slot_is_named_with_its_cleanup_command
test_slot_held_by_a_live_worker_is_silent
test_claim_with_no_record_and_an_unreadable_claim_are_reported_differently
test_unclaimed_slot_reports_nothing
test_claim_with_no_home_is_reported_and_a_foreign_home_stays_silent
