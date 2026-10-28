#!/usr/bin/env bash
# tests/fm-auto-release.test.sh - finished workers are cleaned up without being
# asked: a ship whose PR this home already recorded as merged, and a scout whose
# report exists and whose last status is done, go through the ordinary
# non-force cleanup; a refusal is reported in one line and nothing is forced.
#
# Cleanup itself is bin/fm-teardown.sh's contract and has its own tests, so a
# copy of the release script runs beside a stand-in teardown that logs its
# arguments and answers with the exit code the case names.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-auto-release)

make_home() {  # <name>
  local home="$TMP_ROOT/$1" iso
  iso="$home/iso/bin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$iso"
  cp "$ROOT/bin/fm-auto-release.sh" "$ROOT/bin/fm-pr-lib.sh" "$iso/"
  cat > "$iso/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/teardown.log"
code=$(cat "$FM_HOME/teardown-code.$1" 2>/dev/null || printf 0)
[ "$code" = 0 ] || printf 'error: refusing: %s has unlanded work\n' "$1" >&2
exit "$code"
SH
  chmod +x "$iso/fm-auto-release.sh" "$iso/fm-teardown.sh"
  : > "$home/teardown.log"
  printf '%s\n' "$home"
}

ship() {  # <home> <id> [pr-number]
  local lines=("kind=ship" "mode=no-mistakes" "yolo=off" "worktree=$1/wt-$2")
  [ -z "${3:-}" ] || lines+=("pr=https://github.com/o/r/pull/$3")
  fm_write_meta "$1/state/$2.meta" "${lines[@]}"
}

merged_marker() {  # <home> <id> <pr-number>
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com o/r "$3" > "$1/state/$2.pr-poll-merge-notified"
  chmod 600 "$1/state/$2.pr-poll-merge-notified"
}

scout() {  # <home> <id> <last-status> [report]
  fm_write_meta "$1/state/$2.meta" "kind=scout" "worktree=$1/wt-$2"
  printf 'working [at=1]: started\n%s [at=2]: finished\n' "$3" > "$1/state/$2.status"
  if [ "${4:-}" = report ]; then
    mkdir -p "$1/data/$2"
    printf '# report\n' > "$1/data/$2/report.md"
  fi
}

run_release() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    "$1/iso/bin/fm-auto-release.sh" 2>&1
}

home=$(make_home sweep)
ship "$home" merged-ship 7
merged_marker "$home" merged-ship 7
ship "$home" open-ship 8
ship "$home" other-pr-marker 9
merged_marker "$home" other-pr-marker 10
ship "$home" no-pr
scout "$home" done-scout "done" report
scout "$home" busy-scout working report
scout "$home" reportless-scout "done"
fm_write_meta "$home/state/mate.meta" "kind=secondmate" "home=$home/mate"
out=$(run_release "$home") || fail "the sweep failed: $out"
assert_contains "$out" "released merged-ship (PR merged)" "a merged ship was not released"
assert_contains "$out" "released done-scout (report done)" "a finished scout was not released"
log=$(cat "$home/teardown.log")
assert_contains "$log" "merged-ship" "teardown did not run for the merged ship"
assert_contains "$log" "done-scout" "teardown did not run for the finished scout"
for id in open-ship other-pr-marker no-pr busy-scout reportless-scout mate; do
  assert_not_contains "$log" "$id" "teardown ran for $id, which is not finished"
done
assert_not_contains "$log" "--force" "the sweep forced a teardown"
pass "the sweep cleans up merged ships and finished scouts, and nothing else"

home=$(make_home refused)
ship "$home" dirty-ship 3
merged_marker "$home" dirty-ship 3
printf '1\n' > "$home/teardown-code.dirty-ship"
scout "$home" lost-slot "done" report
printf '4\n' > "$home/teardown-code.lost-slot"
out=$(run_release "$home") || fail "a refused teardown failed the sweep: $out"
assert_contains "$out" "refused dirty-ship (PR merged): error: refusing: dirty-ship has unlanded work" \
  "a refusal was not reported in one line"
assert_equals 1 "$(printf '%s\n' "$out" | grep -c dirty-ship)" "a refusal took more than one line"
assert_contains "$out" "released lost-slot (report done); its pool slot was lost" "a lost slot was not reported"
pass "a refused cleanup is reported in one line and never forced"

home=$(make_home empty)
out=$(run_release "$home") || fail "an empty home failed: $out"
assert_equals "" "$out" "an empty home printed something"
pass "a home with nothing finished prints nothing"
