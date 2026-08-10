#!/usr/bin/env bash
# Regression test for fm-spawn.sh's commitless-repository refusal.
#
# A project created with no initial commit has an unborn HEAD and therefore no
# default branch. treehouse get bases its worktree on refs/remotes/origin/<default>,
# so the acquisition fails outright ("fatal: invalid reference:
# refs/remotes/origin/master") and the pane never leaves the project. Before the
# refusal existed, fm-spawn could only observe that as an elapsed deadline: it
# polled for sixty seconds and reported the wait, naming neither the cause nor the
# remedy, and left behind a window with no state/<id>.meta recording it.
#
# These tests drive the real spawn path against a real commitless clone and pin
# the refusal, its wording, and the fact that nothing survives it. The first test
# also proves the premise itself - that a commitless clone has no branch ref to
# base a worktree on - so the refusal is anchored to the actual failure rather
# than to an assumption about it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-empty-repo)

# A tmux stub that records every subcommand it is asked to run, so a test can
# assert which endpoint operations a spawn did or did not reach. pane_current_path
# answers FM_FAKE_PANE_PATH, defaulting to the project (a pane that never moved).
make_recording_fakebin() {  # <dir> <logfile>
  local dir=$1 log=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?FM_FAKE_TMUX_LOG unset}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  : > "$log"
  printf '%s\n' "$fakebin"
}

make_home() {  # <dir> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
}

run_spawn() {  # <home> <fakebin> <log> <pane-path> <id> <project>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$3" FM_FAKE_PANE_PATH="$4" \
    PATH="$2:$PATH" \
    "$SPAWN" "$5" "$6" --mode no-mistakes --yolo off 2>&1
}

# The incident shape: a repository created empty on the forge, cloned locally,
# and dispatched into before it ever received a commit.
test_commitless_project_is_refused_with_cause_and_remedy() {
  local case_dir home proj bare fakebin log id out status
  id=empty-repo-refusal-e1
  case_dir="$TMP_ROOT/refusal"
  home="$case_dir/home"
  proj="$case_dir/project"
  bare="$case_dir/origin.git"
  log="$case_dir/tmux.log"
  mkdir -p "$case_dir"
  git init -q --bare "$bare"
  git clone -q "$bare" "$proj" 2>/dev/null
  make_home "$home" "$id"
  fakebin=$(make_recording_fakebin "$case_dir/fake" "$log")

  # The premise: with no commits there is no branch ref for a worktree to be
  # based on, which is exactly what treehouse get resolves and fails on.
  git -C "$proj" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
    && fail "fixture is not commitless: HEAD resolves in $proj"
  git -C "$proj" rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    && fail "fixture has a default-branch ref: a worktree could be based on it"

  out=$(run_spawn "$home" "$fakebin" "$log" "$proj" "$id" "$proj")
  status=$?
  expect_code 1 "$status" "spawn into a commitless repository should refuse"
  assert_contains "$out" "has no commits" "the refusal does not name the cause"
  assert_contains "$out" "no default branch" "the refusal does not name why that blocks the launch"
  assert_contains "$out" "one initial commit pushed to its default branch" \
    "the refusal does not name the remedy"
  assert_not_contains "$out" "timeout" "the refusal is reported as a timeout"
  assert_not_contains "$out" "within 60s" "the refusal is reported as an elapsed deadline"
  pass "a spawn into a commitless repository is refused, naming the cause and the remedy"
}

# The second half of the incident: the failed spawn left a window behind with no
# durable record of it, so a naive retry collided with the stray window.
test_refused_spawn_leaves_no_endpoint_or_record() {
  local case_dir home proj bare fakebin log id status
  id=empty-repo-nothing-left-e2
  case_dir="$TMP_ROOT/nothing-left"
  home="$case_dir/home"
  proj="$case_dir/project"
  bare="$case_dir/origin.git"
  log="$case_dir/tmux.log"
  mkdir -p "$case_dir"
  git init -q --bare "$bare"
  git clone -q "$bare" "$proj" 2>/dev/null
  make_home "$home" "$id"
  fakebin=$(make_recording_fakebin "$case_dir/fake" "$log")

  run_spawn "$home" "$fakebin" "$log" "$proj" "$id" "$proj" >/dev/null
  status=$?
  expect_code 1 "$status" "spawn into a commitless repository should refuse"
  assert_no_grep "new-window" "$log" \
    "the refused spawn created a window; a retry would collide with it"
  assert_no_grep "send-keys" "$log" \
    "the refused spawn typed into an endpoint it should never have created"
  assert_absent "$home/state/$id.meta" "the refused spawn recorded task metadata"
  assert_absent "$home/state/$id.status" "the refused spawn recorded task status"
  pass "a refused spawn leaves no window and no durable task record behind"
}

# The refusal must key on the absence of commits, not on the project being new:
# a repository with one commit still spawns exactly as before.
test_repository_with_commits_still_spawns() {
  local case_dir home proj wt fakebin log id out status
  id=empty-repo-control-e3
  case_dir="$TMP_ROOT/control"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/tmux.log"
  mkdir -p "$case_dir"
  fm_git_worktree "$proj" "$wt" control-branch
  make_home "$home" "$id"
  fakebin=$(make_recording_fakebin "$case_dir/fake" "$log")

  out=$(run_spawn "$home" "$fakebin" "$log" "$wt" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "spawn into a repository with commits should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "meta did not record the worktree"
  pass "a repository with commits is unaffected by the refusal"
}

# The other side of the same contract: once an endpoint exists, a failure keeps
# it and names it. That is deliberate - an isolation failure is a stop-and-inspect
# result, and the window is the evidence - so what must hold is that the failure
# is never silent about the window it left. This is what makes refusing BEFORE the
# endpoint exists the fix for the commitless case rather than adding a sweep.
test_failure_after_the_endpoint_exists_names_the_window_it_keeps() {
  local case_dir home proj notrepo fakebin log id out status
  id=empty-repo-post-endpoint-e4
  case_dir="$TMP_ROOT/post-endpoint"
  home="$case_dir/home"
  proj="$case_dir/project"
  notrepo="$case_dir/not-a-worktree"
  log="$case_dir/tmux.log"
  mkdir -p "$case_dir" "$notrepo"
  fm_git_init_commit "$proj"
  make_home "$home" "$id"
  fakebin=$(make_recording_fakebin "$case_dir/fake" "$log")

  # The pane settles somewhere that is not a worktree, so the isolation guard
  # refuses - after the window was already created.
  out=$(run_spawn "$home" "$fakebin" "$log" "$notrepo" "$id" "$proj")
  status=$?
  expect_code 1 "$status" "a pane that settled outside a worktree should refuse"
  assert_grep "new-window" "$log" "the fixture never reached endpoint creation"
  assert_contains "$out" "did not yield an isolated worktree" "the refusal does not name the isolation failure"
  assert_contains "$out" "fm-$id" "the refusal does not name the window it left behind"
  assert_absent "$home/state/$id.meta" "a refused spawn recorded task metadata"
  pass "a failure after the endpoint exists keeps the window and names it for inspection"
}

test_commitless_project_is_refused_with_cause_and_remedy
test_refused_spawn_leaves_no_endpoint_or_record
test_repository_with_commits_still_spawns
test_failure_after_the_endpoint_exists_names_the_window_it_keeps

echo "# all fm-spawn-empty-repo tests passed"
