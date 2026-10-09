#!/usr/bin/env bash
# fm-disk-lens.sh - start, find, or stop disk-lens, the captain's local browser
# view of what holds the Mac's disk, CPU, RAM, and firstmate's own resources.
#
# Usage:
#   fm-disk-lens.sh [start] [--no-open] [--watch-pid <pid>] [--idle-minutes <n>]
#   fm-disk-lens.sh url      print the running instance's page URL
#   fm-disk-lens.sh stop     stop the running instance
#   fm-disk-lens.sh scan [--tabs disk,firstmate] [--no-du] [--top <n>] [--min-mb <n>]
#                            print one read-only scan as JSON (no server, no
#                            browser); bin/fm-disk-lens.py's header owns its shape
#
# start launches bin/fm-disk-lens.py in the background bound to 127.0.0.1 on a
# free port, with a fresh random token (0600 file) that the page URL carries and
# every API request must present, then opens the page in the default browser
# unless --no-open. A second start while one is running reuses it.
# The server stops on the page's Quit button, after --idle-minutes without a
# page request (default 60), or when the watched process exits. --watch-pid
# defaults to the nearest ancestor that is an agent harness process (the
# session that ran the skill); with none found, only Quit and idle stop it.
#
# The server's header (bin/fm-disk-lens.py) owns every safety rule for the
# delete, free, kill, Ask AI, and hand-off actions.
#
# Runtime files live in <FM_HOME>/state/.disk-lens/: token, url, pid, server.log.
#
# Environment:
#   FM_HOME   operational home whose state/, data/, and state/*.meta are used
#             (default: this repository's root).
#
# Exit status: 0 success, 1 failure to start or stop, 2 usage error.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
RUN_DIR="$FM_HOME/state/.disk-lens"

# shellcheck source=bin/fm-agent-process-lib.sh
. "$SELF_DIR/fm-agent-process-lib.sh"

die() { printf 'fm-disk-lens: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

running_pid() {
  local pid
  [ -s "$RUN_DIR/pid" ] || return 1
  pid=$(cat "$RUN_DIR/pid")
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q 'fm-disk-lens.py' || return 1
  printf '%s\n' "$pid"
}

agent_ancestor() {
  local pid=$PPID comm args argv0 hops=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 32 ]; do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
    args=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
    argv0=${args%% *}
    if [ "$(fm_agent_process_classify "$comm" "$argv0" "$args" "$pid")" = agent ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  return 1
}

cmd_start() {
  local open=1 watch_pid="" idle=60 pid url _
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-open) open=0 ;;
      --watch-pid) watch_pid=${2:?--watch-pid needs a pid}; shift ;;
      --idle-minutes) idle=${2:?--idle-minutes needs a number}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
  if pid=$(running_pid) && [ -s "$RUN_DIR/url" ]; then
    url=$(cat "$RUN_DIR/url")
  else
    [ -n "$watch_pid" ] || watch_pid=$(agent_ancestor || true)
    rm -f "$RUN_DIR/url"
    (umask 077 && python3 -c 'import secrets; print(secrets.token_hex(32))' >"$RUN_DIR/token")
    nohup python3 "$SELF_DIR/fm-disk-lens.py" \
      --home "$FM_HOME" \
      --token-file "$RUN_DIR/token" \
      --url-file "$RUN_DIR/url" \
      --idle-minutes "$idle" \
      ${watch_pid:+--watch-pid "$watch_pid"} \
      >"$RUN_DIR/server.log" 2>&1 </dev/null &
    pid=$!
    printf '%s\n' "$pid" >"$RUN_DIR/pid"
    for _ in $(seq 1 100); do
      [ -s "$RUN_DIR/url" ] && break
      kill -0 "$pid" 2>/dev/null || die "server exited at start: $(tail -5 "$RUN_DIR/server.log")"
      sleep 0.1
    done
    [ -s "$RUN_DIR/url" ] || die "server did not report its address within 10s (log: $RUN_DIR/server.log)"
    url=$(cat "$RUN_DIR/url")
  fi
  printf 'disk-lens running (pid %s%s)\n%s\n' "$pid" "${watch_pid:+, stops with pid $watch_pid}" "$url"
  if [ "$open" -eq 1 ]; then
    if command -v open >/dev/null 2>&1; then
      open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" >/dev/null 2>&1 &
    fi
  fi
}

cmd_stop() {
  local pid _
  pid=$(running_pid) || { printf 'disk-lens is not running\n'; return 0; }
  kill -TERM "$pid"
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && die "pid $pid did not stop after SIGTERM"
  rm -f "$RUN_DIR/pid" "$RUN_DIR/url" "$RUN_DIR/token"
  printf 'disk-lens stopped\n'
}

case "${1:-start}" in
  start) [ $# -eq 0 ] || shift; cmd_start "$@" ;;
  -h | --help | help) usage ;;
  --*) cmd_start "$@" ;;
  url)
    if [ -s "$RUN_DIR/url" ] && running_pid >/dev/null; then cat "$RUN_DIR/url"; else die "disk-lens is not running"; fi
    ;;
  stop) cmd_stop ;;
  scan) shift; exec python3 "$SELF_DIR/fm-disk-lens.py" --home "$FM_HOME" --scan-json "$@" ;;
  *) usage >&2; exit 2 ;;
esac
