#!/usr/bin/env bash
# tests/fm-wake-drain-scale.test.sh - a drain must not launch a stat per status
# field per task. Status presentation reads every task log's identity, size, and
# mtime several times; with one stat process per read, a home of about 150 task
# logs paid over 6000 process launches per drain, which on a host where a launch
# costs tens of milliseconds ran past 300s and never reached the acknowledgement
# line. Launch cost is host-dependent, so this pins the launch count instead of
# wall time: the drain's own xtrace names every stat it runs.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TASKS=10
MAX_STATS_PER_TASK=5

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-scale-tests)

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# Run one drain under xtrace and print how many stat processes it launched.
drain_stat_count() {  # <state> <out>
  FM_STATE_OVERRIDE="$1" PS4='+ ' bash -x "$DRAIN" 2>&1 >"$2" \
    | grep -cE '^\++ (LC_ALL=C )?(/usr/bin/)?stat '
}

prime_tasks() {  # <state>
  local i=1
  while [ "$i" -le "$TASKS" ]; do
    printf 'working [at=1700000000]: task %s bootstrap\n' "$i" > "$1/task-$i.status"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$1" "$DRAIN" >/dev/null 2>&1 \
    || fail "bootstrap drain failed while priming $TASKS presentation cursors"
}

test_drain_stat_launches_do_not_multiply_per_field() {
  local dir state out i count
  dir=$(make_case every-task-new-line)
  state="$dir/state"
  out="$dir/drain.out"
  prime_tasks "$state"
  i=1
  while [ "$i" -le "$TASKS" ]; do
    printf 'note: task %s answer\n' "$i" >> "$state/task-$i.status"
    i=$((i + 1))
  done
  count=$(drain_stat_count "$state" "$out")
  i=1
  while [ "$i" -le "$TASKS" ]; do
    grep -F "task-$i note: task $i answer" "$out" >/dev/null \
      || fail "the drain did not present task-$i's new line: $(cat "$out")"
    i=$((i + 1))
  done
  [ "$count" -le $((TASKS * MAX_STATS_PER_TASK)) ] \
    || fail "drain over $TASKS changed tasks launched $count stat processes, above $((TASKS * MAX_STATS_PER_TASK))"
  pass "drain over $TASKS changed tasks presents every new line with $count stat launches"
}

test_quiet_drain_stat_launches_do_not_multiply_per_field() {
  local dir state out count
  dir=$(make_case no-task-changed)
  state="$dir/state"
  out="$dir/drain.out"
  prime_tasks "$state"
  count=$(drain_stat_count "$state" "$out")
  [ "$count" -le $((TASKS * MAX_STATS_PER_TASK)) ] \
    || fail "drain over $TASKS unchanged tasks launched $count stat processes, above $((TASKS * MAX_STATS_PER_TASK))"
  pass "drain over $TASKS unchanged tasks launches $count stat processes"
}

# The presentation cursor manifest holds one row per task and is re-read for
# each task, so a subshell per manifest row grows with the square of the fleet.
# A tab field separator built with a command substitution is such a subshell.
test_drain_row_reads_do_not_launch_subshells() {
  local dir state out count
  dir=$(make_case row-read-subshells)
  state="$dir/state"
  out="$dir/drain.out"
  prime_tasks "$state"
  count=$(FM_STATE_OVERRIDE="$state" PS4='+ ' bash -x "$DRAIN" 2>&1 >"$out" \
    | grep -cE "^\++ printf '\\\\t'$")
  [ "$count" -le "$TASKS" ] \
    || fail "drain over $TASKS tasks launched $count tab-separator subshells, above $TASKS"
  pass "drain over $TASKS tasks launches $count tab-separator subshells"
}

test_drain_stat_launches_do_not_multiply_per_field
test_quiet_drain_stat_launches_do_not_multiply_per_field
test_drain_row_reads_do_not_launch_subshells
