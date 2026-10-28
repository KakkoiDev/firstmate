#!/usr/bin/env bash
# fm-todo-guard.sh - name the captain's open notes-keeping todos that no work owns.
#
# The notes-keeping plugin turns todo changes into captain inbox notes
# (bin/fm-inbox.sh note, one body line `notes-keeping todo changed in <file>:`),
# and its bridge, config/notes-keeping-bridge, links a todo to the task working
# on it. A note acknowledged without dispatching anything leaves the todo with no
# owner and nothing ever says so. This command prints that gap.
#
# Usage:
#   fm-todo-guard.sh unowned [--notes <notes-file>]... [--note <inbox-note>]...
#   fm-todo-guard.sh record-outcome <task-id> [--pr <url>] [--report <path>]
#
# `unowned` prints an `UNOWNED TODOS` section listing every open item (`[ ]` or
# `[~]`) under the `Todo` heading of each notes file that no work owns, then
# exits 1; it prints nothing and exits 0 when every open item is owned.
# An item is owned when the bridge's `status` links it to a task it reports
# in-progress or done, or to a task this home's backlog still has
# (bin/fm-tasks-axi.sh show), which covers a queued item, a captain hold, and
# a finished task whose PR or report the backlog records.
# An item's key is its text after any `**label**: ` prefix, lowercased with
# whitespace collapsed, the same key the plugin and the bridge use.
# The notes files are the --notes arguments plus the files the --note inbox
# records name; with neither, they are the files named by notes-keeping inbox
# notes, pending or handled, received in the last three days.
# When config/notes-keeping-bridge is absent the command does nothing and exits 0.
# A bridge that fails or prints something that is not a JSON object exits 2.
#
# `record-outcome` keeps a finished task's outcome where its todo link lives,
# because the bridge derives an item's status from state/<task>.status and
# state/<task>.meta, which cleanup removes. When state/notes-todo-links.jsonl
# links any item to <task-id>, it appends one
# {"task", "outcome", "pr", "report", "at"} line there, outcome `failed` when
# the task's last status state is failed and `done` otherwise; with no link it
# changes nothing. A bridge `status` that reads that line reports the item done
# across restarts. bin/fm-teardown.sh runs it before it retires the status log,
# and never on a --force cleanup, whose discarded work finished nothing.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE
# select the home, as for bin/fm-inbox.sh.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BRIDGE="$CONFIG/notes-keeping-bridge"

die() { printf 'fm-todo-guard: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

cmd_unowned() {
  local notes=() records=() status_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --notes) [ "$#" -ge 2 ] || die "--notes needs a file"; notes+=("$2"); shift 2 ;;
      --note) [ "$#" -ge 2 ] || die "--note needs an inbox record"; records+=("$2"); shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -x "$BRIDGE" ] || return 0
  status_json=$(FM_HOME="$FM_HOME" "$BRIDGE" status "${notes[0]:-.}") \
    || die "the bridge's status failed: $BRIDGE"
  FM_TODO_STATUS="$status_json" python3 - "$STATE/inbox" "$SELF_DIR/fm-tasks-axi.sh" \
    "${#notes[@]}" ${notes[@]+"${notes[@]}"} ${records[@]+"${records[@]}"} <<'PY'
import json, os, re, subprocess, sys, time

inbox, tasks_axi, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
notes = sys.argv[4:4 + count]
records = sys.argv[4 + count:]
WINDOW = 3 * 86400
CHANGED = re.compile(r'^notes-keeping todo changed in (.+):$')
HEADING = re.compile(r'^(#+)\s+(.*?)\s*$')
ITEM = re.compile(r'^\s*[-*] \[([ ~])\] (.*?)\s*$')
LABEL = re.compile(r'^\*\*(.+?)\*\*: (.*)$')

try:
    linked = json.loads(os.environ['FM_TODO_STATUS'])
except ValueError:
    linked = None
if not isinstance(linked, dict):
    print('fm-todo-guard: the bridge status is not a JSON object', file=sys.stderr)
    sys.exit(2)


def key_of(text):
    return ' '.join(text.lower().split())


links = {key_of(text): entry for text, entry in linked.items() if isinstance(entry, dict)}


def named_file(record):
    try:
        with open(record, encoding='utf-8', errors='replace') as f:
            body = f.read().split('\n--\n', 1)
    except OSError:
        return None
    for line in (body[1] if len(body) == 2 else '').splitlines():
        m = CHANGED.match(line)
        if m:
            return m.group(1)
    return None


files = list(notes)
for record in records:
    path = named_file(record)
    if path:
        files.append(path)
if not notes and not records:
    cutoff = time.time() - WINDOW
    for directory in (inbox, os.path.join(inbox, 'handled')):
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            stamp = name.split('-', 1)[0]
            if not name.endswith('.note') or not stamp.isdigit() or int(stamp) < cutoff:
                continue
            path = named_file(os.path.join(directory, name))
            if path:
                files.append(path)

backlog = {}


def in_backlog(task):
    if task not in backlog:
        done = subprocess.run([tasks_axi, 'show', task], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        backlog[task] = done.returncode == 0
    return backlog[task]


def open_items(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()
    except OSError:
        return
    level = 0
    for line in lines:
        m = HEADING.match(line)
        if m:
            if m.group(2).lower() == 'todo':
                level = len(m.group(1))
            elif level and len(m.group(1)) <= level:
                level = 0
            continue
        m = ITEM.match(line) if level else None
        if m:
            label = LABEL.match(m.group(2))
            yield m.group(1), (label.group(2) if label else m.group(2)), (label.group(1) if label else None)


unowned, seen = [], set()
for path in files:
    if path in seen:
        continue
    seen.add(path)
    for mark, text, label in open_items(path):
        link = links.get(key_of(text))
        if link:
            if link.get('status') in ('in-progress', 'done'):
                continue
            task = link.get('task')
            if isinstance(task, str) and task and in_backlog(task):
                continue
        shown = label or text
        shown = shown if len(shown) <= 120 else shown[:117] + '...'
        gone = f' (linked task {link.get("task")} is gone)' if link else ''
        unowned.append(f'- [{mark}] {shown}{gone}  [{path}]')

if unowned:
    print('UNOWNED TODOS (open notes-keeping todos no task, PR, or captain hold owns; dispatch each with bin/fm-spawn.sh --todo "<todo text>", or acknowledge its note with bin/fm-inbox.sh drain --ack <id> --no-dispatch "<reason>"):')
    print('\n'.join(unowned))
    sys.exit(1)
PY
}

cmd_record_outcome() {
  local task=${1:-} pr='' report=''
  [ -n "$task" ] || die "usage: fm-todo-guard.sh record-outcome <task-id> [--pr <url>] [--report <path>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr) [ "$#" -ge 2 ] || die "--pr needs a url"; pr=$2; shift 2 ;;
      --report) [ "$#" -ge 2 ] || die "--report needs a path"; report=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -f "$STATE/notes-todo-links.jsonl" ] || return 0
  python3 - "$STATE/notes-todo-links.jsonl" "$STATE/$task.status" "$task" "$pr" "$report" <<'PY'
import json, re, sys, time

links, status, task, pr, report = sys.argv[1:6]
linked = False
with open(links, encoding='utf-8', errors='replace') as f:
    for line in f:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get('task') == task and isinstance(record.get('key'), str):
            linked = True
if not linked:
    sys.exit(0)
last = None
try:
    with open(status, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = re.match(r'^(working|needs-decision|blocked|paused|done|failed)(?: \[[^\]]*\])?:', line)
            if m:
                last = m.group(1)
except OSError:
    pass
record = {'task': task, 'outcome': 'failed' if last == 'failed' else 'done', 'at': int(time.time())}
if pr:
    record['pr'] = pr
if report:
    record['report'] = report
with open(links, 'a', encoding='utf-8') as f:
    f.write(json.dumps(record, ensure_ascii=False) + '\n')
PY
}

case "${1:-}" in
  unowned) shift; cmd_unowned "$@" ;;
  record-outcome) shift; cmd_record_outcome "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
