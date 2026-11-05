#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-ack.test.sh - a wake acknowledgement must not
# retire a captain inbox note's only wake while that note is still pending.
# Each note gets exactly one wake (bin/fm-inbox.sh announce_note), so a
# sequence-bound --ack-through that consumed its row while the note was still
# outside handled/ left the note with nothing that would ever wake firstmate
# for it again. Portable: real fm-inbox.sh and fm-wake-drain.sh, no harness.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-ack-tests)
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

run_inbox() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$INBOX_BIN" "$@"
}

inbox_rows() {  # <state>
  awk -F '\t' '$3 == "check" && $4 ~ /^inbox:/' "$1/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

note_id_in() {  # <state>
  find "$1/inbox" -maxdepth 1 -name '*.note' | sed -n 's#.*/\([^/]*\)\.note$#\1#p' | head -n 1
}

test_ack_refuses_while_note_pending() {
  local dir state err ack_err id rc=0
  dir=$(make_case pending)
  state="$dir/state"
  err="$dir/drain.err"
  ack_err="$dir/ack.err"
  run_inbox "$state" note "please review the XiaoXiao update" >/dev/null 2>&1 \
    || fail "setup: fm-inbox.sh note failed"
  id=$(note_id_in "$state")
  [ -n "$id" ] || fail "setup: note file was not written"
  [ "$(inbox_rows "$state")" = 1 ] || fail "setup: expected one inbox wake row"

  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err" || fail "drain failed: $(cat "$err")"
  ack_drain_err "$state" "$err" >/dev/null 2>"$ack_err" || rc=$?

  [ "$rc" -ne 0 ] || fail "ack-through retired the wake of a still-pending note"
  [ "$(inbox_rows "$state")" = 1 ] \
    || fail "the pending note's only wake row was consumed: $(cat "$ack_err")"
  grep -F "$id" "$ack_err" >/dev/null || fail "refusal does not name note $id: $(cat "$ack_err")"
  grep -F "fm-inbox.sh drain --ack $id" "$ack_err" >/dev/null \
    || fail "refusal does not name the note acknowledgement command: $(cat "$ack_err")"
  pass "ack-through refuses while an acked range holds a pending inbox note"
}

test_ack_proceeds_after_note_handled() {
  local dir state err id
  dir=$(make_case handled)
  state="$dir/state"
  err="$dir/drain.err"
  run_inbox "$state" note "already dispatched ask" >/dev/null 2>&1 \
    || fail "setup: fm-inbox.sh note failed"
  id=$(note_id_in "$state")

  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err" || fail "drain failed: $(cat "$err")"
  run_inbox "$state" drain --ack "$id" >/dev/null 2>&1 || fail "fm-inbox.sh drain --ack failed"
  ack_drain_err "$state" "$err" >/dev/null 2>"$dir/ack.err" \
    || fail "ack-through refused after the note was handled: $(cat "$dir/ack.err")"
  [ "$(inbox_rows "$state")" = 0 ] || fail "handled note's wake row was not consumed"
  pass "ack-through consumes an inbox wake once its note is handled"
}

test_away_daemon_ack_is_not_refused() {
  local dir state err id lockdir
  dir=$(make_case away-daemon)
  state="$dir/state"
  err="$dir/drain.err"
  run_inbox "$state" note "note while the captain is away" >/dev/null 2>&1 \
    || fail "setup: fm-inbox.sh note failed"
  id=$(note_id_in "$state")
  printf 'away\n' > "$state/.afk"
  lockdir="$state/.supervise-daemon.lock"
  mkdir -p "$lockdir"
  printf '%s\n' "$$" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$" \
    > "$lockdir/pid-identity" || fail "setup: could not record daemon identity"
  [ -s "$lockdir/pid-identity" ] || fail "setup: empty daemon identity"

  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$err" || fail "drain failed: $(cat "$err")"
  ack_drain_err "$state" "$err" >/dev/null 2>"$dir/ack.err" \
    || fail "away daemon ack was refused, which would re-escalate every cycle: $(cat "$dir/ack.err")"
  [ -f "$state/inbox/$id.note" ] || fail "setup: note should still be pending"
  pass "the away daemon, which escalates check rows durably, is not refused"
}

test_ack_refuses_while_note_pending
test_ack_proceeds_after_note_handled
test_away_daemon_ack_is_not_refused
