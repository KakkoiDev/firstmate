#!/usr/bin/env bash
# Regression test for the treehouse pool preflight and the treehouse-get
# failure report in bin/fm-spawn.sh (bin/fm-treehouse-pool-lib.sh).
#
# `treehouse get` runs as text typed into the task pane, so a spawn used to
# learn nothing about why no isolated copy arrived: a full pool and an
# unloadable treehouse.toml both surfaced as the same 60s "did not enter an
# isolated worktree" timeout naming only the directory the shell was still in.
# The cases below pin the two proven causes refusing before any endpoint or
# record exists, a failing get in the pane being reported as soon as it fails,
# and the timeout still standing as the backstop for a pane that hangs with
# nothing to say.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-preflight)

# make_pool_fakebin <dir>: spawn-world tmux plus a treehouse whose `status
# --json` answers from FM_FAKE_TREEHOUSE_JSON / FM_FAKE_TREEHOUSE_ERR and whose
# every other verb exits 0, standing in for the pool the pane would draw from.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = status ]; then
  if [ -n "${FM_FAKE_TREEHOUSE_ERR:-}" ]; then
    printf '%s\n' "$FM_FAKE_TREEHOUSE_ERR" >&2
    exit 1
  fi
  printf '%s\n' "${FM_FAKE_TREEHOUSE_JSON:-[]}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# slot_json <name> <path> <status>: one `treehouse status --json` array element.
slot_json() {
  printf '{"name":"%s","path":"%s","status":"%s","lease_id":"","lease_holder":"","leased_at":null,"processes":[]}' \
    "$1" "$2" "$3"
}

# make_pool_case <name> <id>: a home, a project repo with a two-slot
# treehouse.toml, and two real pooled worktrees of that project standing in for
# the pool's slots. Echoes case_dir|home|project|slot1|slot2|fakebin.
make_pool_case() {
  local name=$1 id=$2 case_dir home proj pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_pool_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  printf 'max_trees = 2\nroot = ""\n' > "$proj/treehouse.toml"
  git -C "$proj" add treehouse.toml
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm config
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" fetch --quiet origin
  mkdir -p "$pool/1" "$pool/2"
  git -C "$proj" worktree add --quiet --detach "$pool/1/repo"
  git -C "$proj" worktree add --quiet --detach "$pool/2/repo"
  fm_test_spawn_brief "$home" "$id" "Exercise the pool preflight for $id."
  printf '%s\n' "$case_dir|$home|$proj|$pool/1/repo|$pool/2/repo|$fakebin"
}

read_pool_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR SLOT1 SLOT2 FAKEBIN_DIR <<EOF
$1
EOF
}

run_pool_spawn() {
  local id=$1
  fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# A preflight refusal happens before the spawn writes anything for the task at
# all, so nothing about it may exist afterwards.
assert_no_task_state() {  # <home> <id> <what>
  local home=$1 id=$2 what=$3
  assert_no_task_meta "$home" "$id" "$what"
  [ ! -e "$home/data/$id/launch-brief.md" ] || fail "$what rendered a launch brief"
}

# A refusal in the pane stage happens after the launch instructions are
# rendered, so the guarantee there is narrower: no task metadata is published,
# which is what would otherwise point supervision at a worker that never ran.
assert_no_task_meta() {  # <home> <id> <what>
  local home=$1 id=$2 what=$3
  [ ! -e "$home/state/$id.meta" ] || fail "$what published task metadata"
  [ ! -e "$home/state/$id.status" ] || fail "$what left a task status log"
}

# The incident: every worktree in the pool is dirty and the pool is at its cap,
# so `treehouse get` can never return a copy. The refusal must arrive before any
# endpoint or record exists and must carry the whole picture - the counts, the
# cap, and per blocked slot the commands that preserve and then clear it.
test_full_pool_refuses_with_an_actionable_report() {
  local rec id out status
  id='pool-full-p1'
  rec=$(make_pool_case pool-full "$id")
  read_pool_record "$rec"
  printf 'leftover\n' >> "$SLOT1/README.md"
  mkdir -p "$SLOT2/scratch" && printf 'x\n' > "$SLOT2/scratch/x"

  out=$(FM_FAKE_TREEHOUSE_JSON="[$(slot_json 1 "$SLOT1" dirty),$(slot_json 2 "$SLOT2" dirty)]" \
    run_pool_spawn "$id")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn launched a worker into a pool with no obtainable copy"$'\n'"$out"
  assert_contains "$out" "all 2 of 2 worktrees in the pool are in use or dirty (max_trees = 2)" \
    "the refusal did not name the real cause and the cap"
  assert_contains "$out" "0 held by a running worker, 0 held by a durable lease, 2 blocked by leftovers" \
    "the refusal did not break the pool down by what holds each slot"
  assert_contains "$out" "leftovers only: 1 modified tracked file(s), 0 untracked path(s)" \
    "the refusal did not describe slot 1's leftovers"
  assert_contains "$out" "leftovers only: 0 modified tracked file(s), 1 untracked path(s)" \
    "the refusal did not describe slot 2's leftovers"
  assert_contains "$out" "then clear:     treehouse return --force '$SLOT1'" \
    "the refusal did not print the exact command that clears slot 1"
  assert_contains "$out" "preserve first: (cd '$SLOT1'" \
    "the refusal did not print the command that preserves slot 1 first"
  assert_contains "$out" "edit line 1 of $PROJ_DIR/treehouse.toml" \
    "the refusal did not say where the cap is read from"
  assert_contains "$out" "a second max_trees key makes treehouse refuse the file entirely" \
    "the refusal did not warn against appending a duplicate cap key"
  assert_no_task_state "$HOME_DIR" "$id" "the pool-full refusal"
  pass "a pool with no obtainable copy refuses before any record exists, naming cause and remedy"
}

# A slot carrying commits that are not on the default branch is unlanded work,
# never a leftover: it is named as such and offered no clearing command, because
# discarding it is the captain's call alone.
test_unlanded_slot_is_reported_without_a_clearing_command() {
  local rec id out status
  id='pool-unlanded-p2'
  rec=$(make_pool_case pool-unlanded "$id")
  read_pool_record "$rec"
  printf 'real work\n' >> "$SLOT1/README.md"
  git -C "$SLOT1" -c user.name=t -c user.email=t@example.invalid commit -aqm "unlanded work"
  printf 'leftover\n' >> "$SLOT1/README.md"
  printf 'leftover\n' >> "$SLOT2/README.md"

  out=$(FM_FAKE_TREEHOUSE_JSON="[$(slot_json 1 "$SLOT1" dirty),$(slot_json 2 "$SLOT2" dirty)]" \
    run_pool_spawn "$id")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn launched a worker into a pool with no obtainable copy"$'\n'"$out"
  assert_contains "$out" "unlanded work: 1 commit(s) not on" \
    "the refusal did not distinguish the slot holding real unlanded work"
  assert_not_contains "$out" "treehouse return --force '$SLOT1'" \
    "the refusal offered to clear a slot holding unlanded work"
  assert_contains "$out" "treehouse return --force '$SLOT2'" \
    "the refusal did not offer to clear the slot holding only leftovers"
  pass "a slot holding unlanded commits is reported as work, with no command that would discard it"
}

# A treehouse.toml treehouse will not load produced the same unhelpful timeout.
# It must name the file and repeat treehouse's own diagnosis, line and all.
test_unloadable_config_refuses_naming_file_and_line() {
  local rec id out status
  id='pool-config-p3'
  rec=$(make_pool_case pool-config "$id")
  read_pool_record "$rec"

  out=$(FM_FAKE_TREEHOUSE_ERR='failed to load config: toml: line 3 (last key "max_trees"): Key '"'"'max_trees'"'"' has already been defined.' \
    run_pool_spawn "$id")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn launched a worker although treehouse cannot load its config"$'\n'"$out"
  assert_contains "$out" "treehouse cannot load $PROJ_DIR/treehouse.toml" \
    "the refusal did not name the config file treehouse rejected"
  assert_contains "$out" 'toml: line 3 (last key "max_trees"): Key' \
    "the refusal did not repeat treehouse's own diagnosis"
  assert_no_task_state "$HOME_DIR" "$id" "the unloadable-config refusal"
  pass "an unloadable treehouse.toml refuses naming the file, the line, and the problem"
}

# A `treehouse get` that fails in the pane must be reported as soon as it fails,
# with its exit status and whatever it printed, instead of being waited out.
test_failing_treehouse_get_is_reported_verbatim() {
  local rec id out status fakebin
  id='pool-getfail-p4'
  rec=$(make_pool_case pool-getfail "$id")
  read_pool_record "$rec"
  fakebin=$FAKEBIN_DIR
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  capture-pane) printf '%s\n' "${FM_FAKE_CAPTURE:-}"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  out=$(FM_FAKE_TREEHOUSE_JSON="[$(slot_json 1 "$SLOT1" available)]" \
    FM_FAKE_CAPTURE=$'$ treehouse get\nall 2 worktrees are in use or dirty (max_trees = 2). Run treehouse status to see details\nFM_TREEHOUSE_GET_FAILED 1' \
    FM_SPAWN_WORKTREE_WAIT=30 run_pool_spawn "$id")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn ignored a treehouse get that failed in the pane"$'\n'"$out"
  assert_contains "$out" "treehouse get could not hand task $id an isolated copy" \
    "the refusal did not report the failing get"
  assert_contains "$out" "it exited 1" \
    "the refusal did not carry the exit status treehouse get reported"
  assert_contains "$out" "all 2 worktrees are in use or dirty (max_trees = 2)" \
    "the refusal did not repeat what the task terminal actually showed"
  assert_not_contains "$out" "did not enter an isolated worktree within" \
    "the failing get was waited out instead of being reported when it failed"
  assert_no_task_meta "$HOME_DIR" "$id" "the failing-get refusal"
  pass "a treehouse get that fails in the pane is reported at once, in its own words"
}

# The wait is still the backstop for a pane that hangs with nothing to report:
# no failure marker, no movement, a pool that can hand out a copy.
test_hanging_pane_still_hits_the_timeout_backstop() {
  local rec id out status
  id='pool-hang-p5'
  rec=$(make_pool_case pool-hang "$id")
  read_pool_record "$rec"

  out=$(FM_FAKE_TREEHOUSE_JSON="[$(slot_json 1 "$SLOT1" available)]" \
    FM_SPAWN_WORKTREE_WAIT=3 run_pool_spawn "$id")
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the project"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree within 3s" \
    "the timeout backstop did not fire on a pane that reported nothing"
  assert_contains "$out" "the pool reports a copy is obtainable" \
    "the timeout did not say what the pool had to say about the cause"
  assert_no_task_meta "$HOME_DIR" "$id" "the timeout refusal"
  pass "a pane that hangs with nothing to report still fails at the wait's deadline"
}

test_full_pool_refuses_with_an_actionable_report
test_unlanded_slot_is_reported_without_a_clearing_command
test_unloadable_config_refuses_naming_file_and_line
test_failing_treehouse_get_is_reported_verbatim
test_hanging_pane_still_hits_the_timeout_backstop

echo "# all fm-spawn-pool-preflight tests passed"
