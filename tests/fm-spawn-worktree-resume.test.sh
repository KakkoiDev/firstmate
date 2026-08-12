#!/usr/bin/env bash
# Regression test for resuming a task in the worktree it is already recorded in
# (bin/fm-spawn.sh's RESUME_WT_NAME path).
#
# A worker stopped with work still in its worktree leaves that worktree dirty,
# and `treehouse get` only hands out worktrees the pool reports as available. So
# a plain re-spawn was handed a DIFFERENT worktree: the task's branch and commits
# stayed stranded in the old one, and because git refuses a second checkout of
# the same branch the relaunched worker failed at its first step. When
# state/<id>.meta records a worktree that still exists in the same repository,
# the spawn must enter that worktree by its pool name instead of allocating.
#
# Sharing one worktree makes a second agent in it the new hazard, so the resume
# path must also refuse when the recorded worker is anything other than
# positively gone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-resume)

# make_resume_fakebin <dir> <settled-path> <treehouse-log> <send-log> builds:
#   tmux       - a pane whose cwd is always <settled-path>, whose agent-state
#                inventory reports no such window (so the recorded worker reads
#                authoritatively gone unless a case overrides it), and which logs
#                every send-keys payload so the command the spawn actually ran in
#                the pane is observable.
#   treehouse  - logs its argv, and answers `enter --print-path <name>` with the
#                pool path for that name so the spawn can verify the name it
#                derived actually resolves back to the recorded worktree.
make_resume_fakebin() {
  local dir=$1 settled=$2 log=$3 sendlog=$4 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$settled"; exit 0 ;;
esac
case "\${1:-}" in
  list-panes)
    # A window inventory that omits the recorded window: authoritatively gone.
    if [ -n "\${FM_FAKE_RECORDED_WINDOW_LIVE:-}" ]; then
      printf '%s\n' "\${FM_FAKE_RECORDED_WINDOW_NAME:-}"
      exit 0
    fi
    exit 0
    ;;
  list-windows)
    if [ -n "\${FM_FAKE_RECORDED_WINDOW_LIVE:-}" ]; then
      printf '%s\n' "\${FM_FAKE_RECORDED_WINDOW_NAME:-}"
    fi
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) printf '%s\n' "\$*" >> "$sendlog"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = enter ]; then
  name=""
  for a in "\$@"; do
    case "\$a" in
      enter|--print-path) ;;
      *) name=\$a ;;
    esac
  done
  path="${settled%/*/*}/\$name/$(basename "$settled")"
  [ -d "\$path" ] || exit 1
  printf '%s\n' "\$path"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_resume_case <name> <id> builds a home, a project, and a pool-shaped
# worktree at <case>/pool/<POOL_NAME>/<repo-basename>, mirroring treehouse's own
# layout so the pool name is derivable from the recorded path. The worktree is
# left dirty, which is exactly the state that makes `treehouse get` skip it.
POOL_NAME=7
make_resume_case() {
  local name=$1 id=$2 case_dir home proj wt log sendlog fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/pool/$POOL_NAME/project"
  log="$case_dir/treehouse.log"
  sendlog="$case_dir/send.log"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/pool/$POOL_NAME"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf 'work in progress\n' > "$wt/UNCOMMITTED.md"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat" "$log" "$sendlog"
  fakebin=$(make_resume_fakebin "$case_dir/fake" "$wt" "$log" "$sendlog")
  printf '%s\n' "$case_dir|$home|$proj|$wt|$log|$sendlog|$fakebin"
}

read_resume_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR TH_LOG SEND_LOG FAKEBIN_DIR <<EOF
$1
EOF
}

run_resume_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# The core regression: a recorded, still-present worktree is entered by its pool
# name, and the task keeps that worktree instead of being handed a fresh one.
test_recorded_worktree_is_reentered() {
  local rec id out status
  id=resume-recorded-w1
  rec=$(make_resume_case resume-recorded "$id")
  read_resume_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_resume_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should resume into the recorded worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta no longer records the worktree the task's work lives in"
  assert_grep "enter --print-path $POOL_NAME" "$TH_LOG" \
    "the pool name was never resolved against the live pool"
  assert_grep "treehouse enter $POOL_NAME" "$SEND_LOG" \
    "the worker was not moved into the recorded worktree"
  assert_no_grep "treehouse get" "$SEND_LOG" \
    "spawn allocated a fresh worktree instead of resuming the recorded one"
  [ -f "$WT_DIR/UNCOMMITTED.md" ] || fail "the recorded worktree's uncommitted work did not survive"
  pass "a recorded, still-present worktree is re-entered rather than reallocated"
}

# With no worktree recorded there is nothing to strand, so the ordinary
# allocation path must still be the one used.
test_fresh_task_still_allocates() {
  local rec id out status
  id=resume-fresh-w2
  rec=$(make_resume_case resume-fresh "$id")
  read_resume_record "$rec"

  out=$(run_resume_spawn "$id")
  status=$?
  expect_code 0 "$status" "a fresh task should still allocate from the pool"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "treehouse get" "$SEND_LOG" "a fresh task did not allocate from the pool"
  assert_no_grep "enter --print-path" "$TH_LOG" \
    "a fresh task tried to resume a worktree it never had"
  pass "a task with no recorded worktree still allocates from the pool"
}

# A recorded worktree that no longer exists cannot be resumed, and allocating is
# safe because none of the task's work is there.
test_missing_recorded_worktree_falls_back() {
  local rec id out status
  id=resume-gone-w3
  rec=$(make_resume_case resume-gone "$id")
  read_resume_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$HOME_DIR/no-such-worktree" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_resume_spawn "$id")
  status=$?
  expect_code 0 "$status" "a vanished recorded worktree should fall back to allocation"
  assert_grep "treehouse get" "$SEND_LOG" "spawn did not fall back to allocating a worktree"
  pass "a recorded worktree that no longer exists falls back to allocation"
}

# A worktree recorded from another repository is a corrupt record, never a
# resume target.
test_foreign_worktree_is_not_resumed() {
  local rec id out status other
  id=resume-foreign-w4
  rec=$(make_resume_case resume-foreign "$id")
  read_resume_record "$rec"
  other="$TMP_ROOT/resume-foreign/other-repo/pool/$POOL_NAME/other"
  mkdir -p "$(dirname "$other")"
  fm_git_worktree "$TMP_ROOT/resume-foreign/other-repo/src" "$other" other-branch
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$other" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_resume_spawn "$id")
  status=$?
  expect_code 0 "$status" "a foreign recorded worktree should fall back to allocation"
  assert_grep "treehouse get" "$SEND_LOG" "spawn did not fall back to allocating a worktree"
  assert_no_grep "enter --print-path" "$TH_LOG" \
    "spawn tried to enter a worktree belonging to another repository"
  pass "a worktree recorded from another repository is never resumed"
}

# Two agents in one worktree is worse than the stranding this path prevents, so
# a recorded worker that does not read as gone must stop the spawn.
test_live_recorded_worker_refuses() {
  local rec id out status
  id=resume-live-w5
  rec=$(make_resume_case resume-live "$id")
  read_resume_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(FM_FAKE_RECORDED_WINDOW_LIVE=1 FM_FAKE_RECORDED_WINDOW_NAME="fm-$id" \
    run_resume_spawn "$id")
  status=$?
  [ "$status" != 0 ] || fail "spawn launched a second agent into an occupied worktree"
  assert_contains "$out" "refusing to launch a second agent into one worktree" \
    "the refusal did not name the shared-worktree hazard"
  pass "a recorded worker that does not read as gone stops the resume"
}

# Two unfinished tasks recorded in one worktree is a tangle. Entering it would put
# this task's branch where the other task's branch is checked out, which git
# refuses, so the spawn must name both and stop.
test_worktree_claimed_by_another_task_refuses() {
  local rec id out status
  id=resume-tangled-w6
  rec=$(make_resume_case resume-tangled "$id")
  read_resume_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"
  fm_write_meta "$HOME_DIR/state/other-task-w7.meta" \
    "window=firstmate:fm-other-task-w7" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"

  out=$(run_resume_spawn "$id")
  status=$?
  [ "$status" != 0 ] || fail "spawn launched into a worktree another unfinished task claims"
  assert_contains "$out" "other-task-w7" "the refusal did not name the conflicting task"
  pass "a worktree claimed by another unfinished task stops the resume"
}

test_recorded_worktree_is_reentered
test_fresh_task_still_allocates
test_missing_recorded_worktree_falls_back
test_foreign_worktree_is_not_resumed
test_live_recorded_worker_refuses
test_worktree_claimed_by_another_task_refuses

echo "# all fm-spawn-worktree-resume tests passed"
