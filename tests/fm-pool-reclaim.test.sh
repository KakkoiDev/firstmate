#!/usr/bin/env bash
# Behavioral coverage for bin/fm-pool-reclaim.sh on fake pool data.
#
# The portable cases build real linked worktrees in Treehouse's
# <pool>/<slot>/<repo> layout, describe them through a fake `treehouse status
# --json`, and record every `treehouse return` call, so each slot shape the
# 2026-10-29 pool-full incident showed is pinned: what is made reusable, what
# is released, and what is kept untouched with its cause.
# The final case drives the real Treehouse binary when it is installed: a slot
# landed only on a diverged local default branch fills a one-slot pool until
# reclaim detaches it, after which Treehouse hands the same slot out again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECLAIM="$ROOT/bin/fm-pool-reclaim.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-reclaim)
GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# A project whose local main has diverged from origin/main, as local-only
# landings leave it, plus a fake treehouse and tmux on PATH.
make_world() {  # <name>
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/fakebin" "$w/pool"
  git init -q -b main "$w/project"
  git -C "$w/project" "${GIT_ID[@]}" commit -q --allow-empty -m initial
  git clone -q --bare "$w/project" "$w/origin.git"
  git -C "$w/project" remote add origin "$w/origin.git"
  git clone -q "$w/origin.git" "$w/publisher"
  printf 'upstream\n' > "$w/publisher/upstream.txt"
  git -C "$w/publisher" add upstream.txt
  git -C "$w/publisher" "${GIT_ID[@]}" commit -q -m upstream
  git -C "$w/publisher" push -q origin main
  printf 'local\n' > "$w/project/local.txt"
  git -C "$w/project" add local.txt
  git -C "$w/project" "${GIT_ID[@]}" commit -q -m local-landing
  git -C "$w/project" fetch -q origin
  git -C "$w/project" remote set-head origin main >/dev/null
  printf '[]\n' > "$w/pool/treehouse-state.json"
  printf '[]\n' > "$w/status.json"
  cat > "$w/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\$1" in
  status) cat "$w/status.json" ;;
  return) printf '%s\n' "\$*" >> "$w/returns.log" ;;
  *) exit 64 ;;
esac
SH
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
echo "can't find session: ${3:-x}" >&2
exit 1
SH
  chmod +x "$w/fakebin/treehouse" "$w/fakebin/tmux"
  printf '%s\n' "$w"
}

# add_slot <world> <name> <commit-ish> [branch]: a linked worktree at pool/<name>/repo.
add_slot() {
  local w=$1 name=$2 at=$3 branch=${4:-}
  if [ -n "$branch" ]; then
    git -C "$w/project" worktree add -q -b "$branch" "$w/pool/$name/repo" "$at"
  else
    git -C "$w/project" worktree add -q --detach "$w/pool/$name/repo" "$at"
  fi
}

# pool_entry <world> <name> <status> [holder]: append a treehouse status row.
pool_entry() {
  local w=$1 name=$2 status=$3 holder=${4:-}
  jq --arg n "$name" --arg s "$status" --arg h "$holder" --arg p "$w/pool/$name/repo" \
    '. + [{name: $n, status: $s, lease_holder: $h, processes: [], path: $p}]' \
    "$w/status.json" > "$w/status.json.tmp" && mv "$w/status.json.tmp" "$w/status.json"
}

# task <world> <id> <kind> <slot-name> <last-status> [backend]: a task record and slot claim.
task() {
  local w=$1 id=$2 kind=$3 name=$4 last=$5 backend=${6:-tmux}
  printf 'window=fm-main:fm-%s\nworktree=%s\nkind=%s\nbackend=%s\n' \
    "$id" "$w/pool/$name/repo" "$kind" "$backend" > "$w/home/state/$id.meta"
  printf '%s [at=1]: x\n' "$last" > "$w/home/state/$id.status"
  printf 'task=%s\nhome=%s\n' "$id" "$w/home" > "$w/pool/$name/.fm-slot-owner"
}

reclaim() {  # <world> <args...>
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" FM_HOME="$w/home" bash "$RECLAIM" "$@" "$w/project" 2>"$w/err"
}

head_of() { git -C "$1" rev-parse HEAD; }

# --- available slots ---------------------------------------------------------

w=$(make_world available)
add_slot "$w" 1 main fm/landed-local          # landed on local main only, branch kept
add_slot "$w" 2 main~0                        # same commit, detached
git -C "$w/project" branch -q fm/unlanded main
git -C "$w/project" worktree add -q "$w/pool/3/repo" fm/unlanded
git -C "$w/pool/3/repo" "${GIT_ID[@]}" commit -q --allow-empty -m unlanded
add_slot "$w" 4 origin/main                   # already reusable
add_slot "$w" 5 main
git -C "$w/pool/5/repo" "${GIT_ID[@]}" commit -q --allow-empty -m only-here
add_slot "$w" 6 origin/main
git init -q "$w/pool/6/repo/scratch/clone"
add_slot "$w" 7 main
printf 'x\n' > "$w/pool/7/repo/notes.txt"
task "$w" released-ship ship 1 "done"                 # a stale claim: its record released the slot
sed -i.bak 's/^worktree=/worktree_released=/' "$w/home/state/released-ship.meta"
add_slot "$w" 8 main fm/paused-ship; task "$w" paused-ship ship 8 paused
add_slot "$w" 9 main fm/legacy-ship; task "$w" legacy-ship ship 9 paused
rm "$w/pool/9/.fm-slot-owner"                         # taken before slot claims existed
add_slot "$w" 10 main fm/far-ship
printf 'task=far-ship\nhome=%s\n' "$w/elsewhere" > "$w/pool/10/.fm-slot-owner"
for n in 1 2 3 4 5; do pool_entry "$w" "$n" available; done
pool_entry "$w" 6 dirty
for n in 7 8 9 10; do pool_entry "$w" "$n" available; done
before5=$(head_of "$w/pool/5/repo")
base=$(git -C "$w/project" merge-base main origin/main)

out=$(reclaim "$w")
printf '%s\n' "$out" | grep -qx 'would-detach 1 head-not-on-base' || fail "dry run names the landed-locally slot: $out"
[ "$(git -C "$w/pool/1/repo" symbolic-ref -q --short HEAD)" = fm/landed-local ] || fail "dry run changed slot 1"
pass "dry run reports without changing a slot"

out=$(reclaim "$w" --apply) || fail "apply exits 0: $(cat "$w/err")"
for n in 1 2 3; do
  printf '%s\n' "$out" | grep -qx "detached $n head-not-on-base" || fail "slot $n detached: $out"
  [ "$(head_of "$w/pool/$n/repo")" = "$base" ] || fail "slot $n sits on the shared base"
  git -C "$w/pool/$n/repo" merge-base --is-ancestor HEAD origin/main || fail "slot $n is reusable against origin/main"
done
git -C "$w/project" rev-parse -q --verify refs/heads/fm/landed-local >/dev/null || fail "landed branch ref survives"
[ "$(git -C "$w/project" log -1 --format=%s fm/unlanded)" = unlanded ] || fail "unlanded branch keeps its commit"
pass "available slots holding a branch or a local-only landing are detached onto the shared base, refs kept"

printf '%s\n' "$out" | grep -q '^[a-z-]* 4 ' && fail "a reusable slot is not reported: $out"
[ "$(head_of "$w/pool/5/repo")" = "$before5" ] || fail "slot 5 HEAD must not move"
printf '%s\n' "$out" | grep -qx 'kept 5 head-not-on-base-and-not-saved' || fail "slot 5 kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 6 unleased-nested-git-repo-1' || fail "nested repo kept: $out"
[ -d "$w/pool/6/repo/scratch/clone/.git" ] || fail "nested repo untouched"
printf '%s\n' "$out" | grep -qx 'kept 7 head-not-on-base-and-not-saved' || fail "dirty slot kept: $out"
[ -f "$w/pool/7/repo/notes.txt" ] || fail "uncommitted file untouched"
[ ! -e "$w/returns.log" ] || fail "no available slot is returned"
pass "slots whose commits or files exist only in the slot are kept untouched"

printf '%s\n' "$out" | grep -qx 'kept 8 claimed-by-paused-ship' || fail "slot a paused task resumes in is kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 9 named-by-legacy-ship' || fail "slot a record names without a claim is kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 10 claimed-by-far-ship:record-unreadable' || fail "slot claimed from an unreadable home is kept: $out"
for n in 8 9 10; do
  git -C "$w/pool/$n/repo" symbolic-ref -q HEAD >/dev/null || fail "slot $n keeps its branch"
done
pass "an available slot a task record still names is kept for that task"

# --- leased slots of finished tasks -----------------------------------------

w=$(make_world leased)
add_slot "$w" 10 origin/main;  task "$w" scout-done scout 10 "done"
add_slot "$w" 11 main fm/ship-landed; task "$w" ship-landed ship 11 "done"
git -C "$w/project" branch -q fm/ship-waiting main
git -C "$w/project" worktree add -q "$w/pool/12/repo" fm/ship-waiting
git -C "$w/pool/12/repo" "${GIT_ID[@]}" commit -q --allow-empty -m waiting
task "$w" ship-waiting ship 12 "done"
add_slot "$w" 13 origin/main;  task "$w" scout-blocked scout 13 "blocked"
add_slot "$w" 14 origin/main;  task "$w" scout-dirty scout 14 "done"
printf 'x\n' > "$w/pool/14/repo/findings.txt"
add_slot "$w" 15 origin/main;  task "$w" scout-unverified scout 15 "done" zellij
add_slot "$w" 16 origin/main
add_slot "$w" 17 main fm/ship-orphaned; task "$w" ship-orphaned ship 17 "done"
printf 'gitdir: %s\n' "$w/project/.git/worktrees/gone" > "$w/pool/17/repo/.git"   # its git link points nowhere
for n in 10 11 12 13 14 15 17; do pool_entry "$w" "$n" leased "$(sed -n 's/^task=//p' "$w/pool/$n/.fm-slot-owner")"; done
pool_entry "$w" 16 leased other-home-task

out=$(reclaim "$w" --apply) || fail "apply exits 0: $(cat "$w/err")"
printf '%s\n' "$out" | grep -qx 'released 10 leased-by-scout-done:done-and-saved' || fail "finished scout released: $out"
printf '%s\n' "$out" | grep -qx 'released 11 leased-by-ship-landed:done-and-saved' || fail "landed ship released: $out"
grep -qx "return --if-lease-holder scout-done $w/pool/10/repo" "$w/returns.log" || fail "return pinned to the lease holder: $(cat "$w/returns.log")"
grep -qx "worktree_released=$w/pool/10/repo" "$w/home/state/scout-done.meta" || fail "record renames worktree="
grep -q '^worktree=' "$w/home/state/scout-done.meta" && fail "record no longer names the slot"
[ ! -e "$w/pool/10/.fm-slot-owner" ] || fail "slot claim dropped"
git -C "$w/pool/11/repo" symbolic-ref -q HEAD >/dev/null && fail "released ship slot is detached"
git -C "$w/project" rev-parse -q --verify refs/heads/fm/ship-landed >/dev/null || fail "landed ship branch ref survives"
pass "a finished task whose work is saved releases its slot and stops naming it"

printf '%s\n' "$out" | grep -qx 'kept 12 leased-by-ship-waiting:done-ship-awaiting-landing' || fail "unlanded ship kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 13 leased-by-scout-blocked:last-status-blocked' || fail "blocked scout kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 14 leased-by-scout-dirty:done-dirty-1' || fail "dirty scout kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 15 leased-by-scout-unverified:done-endpoint-unverified' || fail "unverifiable endpoint kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 16 leased-by-other-home-task:no-record-in-this-home' || fail "foreign lease kept: $out"
printf '%s\n' "$out" | grep -qx 'kept 17 leased-by-ship-orphaned:done-git-unreadable' || fail "slot git cannot read kept: $out"
for id in ship-waiting scout-blocked scout-dirty scout-unverified; do
  grep -q '^worktree=' "$w/home/state/$id.meta" || fail "$id record untouched"
done
[ "$(git -C "$w/pool/12/repo" symbolic-ref -q --short HEAD)" = fm/ship-waiting ] || fail "unlanded ship slot untouched"
[ "$(wc -l < "$w/returns.log" | tr -d ' ')" = 2 ] || fail "only the two saved slots are returned: $(cat "$w/returns.log")"
pass "unlanded, unfinished, dirty, unverifiable, and foreign leases are kept with their cause"

# --- the real Treehouse hands a released slot out again ----------------------

if ! command -v treehouse >/dev/null 2>&1; then
  printf 'ok - # SKIP real treehouse not installed\n'
  exit 0
fi
w=$(make_world real)
rm -f "$w/fakebin/treehouse"
printf 'max_trees = 1\n' > "$w/project/treehouse.toml"
real() { (cd "$w/project" && TREEHOUSE_ROOT="$w/troot" treehouse "$@" 2>/dev/null); }
slot=$(real get --lease --lease-holder scout-real) || fail "first lease"
printf 'window=fm-main:fm-scout-real\nworktree=%s\nkind=scout\nbackend=tmux\n' "$slot" > "$w/home/state/scout-real.meta"
printf 'done [at=1]: report written\n' > "$w/home/state/scout-real.status"
printf 'task=scout-real\nhome=%s\n' "$w/home" > "$(dirname "$slot")/.fm-slot-owner"
real get --lease --lease-holder next >/dev/null && fail "precondition: a one-slot pool is full while the finished scout holds it"
out=$(PATH="$w/fakebin:$PATH" TREEHOUSE_ROOT="$w/troot" FM_HOME="$w/home" bash "$RECLAIM" --apply "$w/project" 2>"$w/err") \
  || fail "reclaim with real treehouse: $(cat "$w/err")"
printf '%s\n' "$out" | grep -qx 'released 1 leased-by-scout-real:done-and-saved' || fail "real release reported: $out $(cat "$w/err")"
again=$(real get --lease --lease-holder next) || fail "Treehouse hands out the released slot: $out"
[ "$again" = "$slot" ] || fail "the same slot is handed out"
pass "real Treehouse hands a finished task's released slot out again"
