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
#   fm-todo-guard.sh resolve <todo text> [--notes <notes-file>]... [--note <inbox-note>]...
#   fm-todo-guard.sh record-outcome <task-id> [--pr <url>] [--report <path>]
#     [--scout [--report-has-captain-call <yes|no>] [--scout-recommends-ship <yes|no>]]
#   fm-todo-guard.sh record-close <task-id>
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
# `resolve` finds the one open item, owned or not, in the same notes files that
# <todo text> names, and prints that item's text. It matches an item whose key
# or label key equals the text's key; failing that, an item whose key or label
# key contains it. An item open in several files is one item. With no match or
# several, it prints the candidates (every open item when nothing matched) and
# exits 1. When config/notes-keeping-bridge is absent it prints the text as given.
#
# `record-outcome` keeps a finished task's outcome where its todo link lives,
# because the bridge derives an item's status from state/<task>.status and
# state/<task>.meta, which cleanup removes. When state/notes-todo-links.jsonl
# links any item to <task-id>, it appends one
# {"task", "outcome", "pr", "report", "at"} line there, outcome `failed` when
# the task's last status state is failed and `done` otherwise; with no link it
# changes nothing. A bridge `status` that reads that line reports the item done
# across restarts. For a --scout, `done` holds only when both readings are `no`,
# because the investigation was then the whole ask; a captain call, a ship
# recommendation, or a missing reading records outcome `open` with kind `scout`,
# which the bridge does not report done, so the todo stays open.
# bin/fm-teardown.sh runs it before it retires the status log, passing --scout
# and its two readings for a scout, and never on a --force cleanup, whose
# discarded work finished nothing.
#
# `record-close` keeps the outcome of a backlog task closed with no worker and
# so no cleanup, such as a captain hold. bin/fm-tasks-axi.sh runs it after a
# successful `done` and bin/fm-captain-hold.sh after an answer closes its task.
# With state/<task-id>.meta present it changes nothing, because cleanup records
# that task. Otherwise it appends a `done` outcome for <task-id> when an item is
# linked to it and has no outcome as new as its latest link, and a `done` outcome, with kind
# `scout` and `followup` <task-id>, for every scout whose latest outcome is
# `open` and whose report the task links (a `report:` link, relative to the
# backlog root), so the scout's todos close with the work its report left.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE
# select the home, as for bin/fm-inbox.sh.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIDGE="$CONFIG/notes-keeping-bridge"

die() { printf 'fm-todo-guard: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

cmd_unowned() {
  local query='' notes=() records=() status_json='{}'
  if [ "$1" = resolve ]; then
    query=${2:-}
    [ -n "$query" ] || die "resolve needs a todo text"
    shift
  fi
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --notes) [ "$#" -ge 2 ] || die "--notes needs a file"; notes+=("$2"); shift 2 ;;
      --note) [ "$#" -ge 2 ] || die "--note needs an inbox record"; records+=("$2"); shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [ ! -x "$BRIDGE" ]; then
    [ -z "$query" ] || printf '%s\n' "$query"
    return 0
  fi
  [ -n "$query" ] || status_json=$(FM_HOME="$FM_HOME" "$BRIDGE" status "${notes[0]:-.}") \
    || die "the bridge's status failed: $BRIDGE"
  FM_TODO_STATUS="$status_json" FM_TODO_QUERY="$query" python3 - "$STATE/inbox" "$SELF_DIR/fm-tasks-axi.sh" \
    "${#notes[@]}" ${notes[@]+"${notes[@]}"} ${records[@]+"${records[@]}"} <<'PY'
import json, os, re, subprocess, sys, time

inbox, tasks_axi, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
notes = sys.argv[4:4 + count]
records = sys.argv[4 + count:]
query = os.environ['FM_TODO_QUERY']
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


if query:
    items = {}
    for path in dict.fromkeys(files):
        for mark, text, label in open_items(path):
            items.setdefault(key_of(text), (mark, text, label))
    want = key_of(query)
    keys = lambda item: [key_of(item[1])] + ([key_of(item[2])] if item[2] else [])
    found = [i for i in items.values() if want in keys(i)] \
        or [i for i in items.values() if any(want in k for k in keys(i))]
    if len(found) == 1:
        print(found[0][1])
        sys.exit(0)
    shown = found or list(items.values())
    print(f'no open notes-keeping todo matches "{query}"' if not found
          else f'"{query}" matches {len(found)} open notes-keeping todos; name exactly one')
    print('\n'.join(f'- [{m}] {f"**{l}**: " if l else ""}{t}' for m, t, l in shown) or '(no open todos found)')
    sys.exit(1)

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
  local task=${1:-} pr='' report='' scout='' captain_call='' recommends_ship=''
  [ -n "$task" ] || die "usage: fm-todo-guard.sh record-outcome <task-id> [--pr <url>] [--report <path>] [--scout ...]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr) [ "$#" -ge 2 ] || die "--pr needs a url"; pr=$2; shift 2 ;;
      --report) [ "$#" -ge 2 ] || die "--report needs a path"; report=$2; shift 2 ;;
      --scout) scout=1; shift ;;
      --report-has-captain-call) [ "$#" -ge 2 ] || die "$1 needs yes or no"; captain_call=$2; shift 2 ;;
      --scout-recommends-ship) [ "$#" -ge 2 ] || die "$1 needs yes or no"; recommends_ship=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -f "$STATE/notes-todo-links.jsonl" ] || return 0
  python3 - "$STATE/notes-todo-links.jsonl" "$STATE/$task.status" "$task" "$pr" "$report" \
    "$scout" "$captain_call" "$recommends_ship" <<'PY'
import json, re, sys, time

links, status, task, pr, report, scout, captain_call, recommends_ship = sys.argv[1:9]
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
if scout and record['outcome'] == 'done' and (captain_call, recommends_ship) != ('no', 'no'):
    record['outcome'] = 'open'
    record['kind'] = 'scout'
if pr:
    record['pr'] = pr
if report:
    record['report'] = report
with open(links, 'a', encoding='utf-8') as f:
    f.write(json.dumps(record, ensure_ascii=False) + '\n')
PY
}

cmd_record_close() {
  local task=${1:-} show
  [ -n "$task" ] && [ "$#" -eq 1 ] || die "usage: fm-todo-guard.sh record-close <task-id>"
  [ -f "$STATE/notes-todo-links.jsonl" ] || return 0
  [ ! -e "$STATE/$task.meta" ] || return 0
  show=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SELF_DIR/fm-tasks-axi.sh" show "$task" --full) \
    || die "cannot read task $task from the backlog"
  FM_TODO_SHOW="$show" python3 - "$STATE/notes-todo-links.jsonl" "$task" "$(dirname "$DATA")" <<'PY'
import json, os, re, sys, time

links, task, root = sys.argv[1:4]
records = []
with open(links, encoding='utf-8', errors='replace') as f:
    for line in f:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and isinstance(record.get('task'), str):
            records.append(record)
linked, latest = {}, {}
for r in records:
    if isinstance(r.get('key'), str):
        linked[r['task']] = r.get('at', 0)
    elif isinstance(r.get('outcome'), str):
        latest[r['task']] = r
m = re.search(r'^\s*links: "(.*)"\s*$', os.environ['FM_TODO_SHOW'], re.M)
reports = set()
for link in (m.group(1).split(',') if m else []):
    if link.startswith('report:') and link[7:]:
        reports.add(os.path.realpath(os.path.join(root, link[7:])))
now = int(time.time())
out = []
if task in linked and (task not in latest or latest[task].get('at', 0) < linked[task]):
    out.append({'task': task, 'outcome': 'done', 'at': now, 'kind': 'closed'})
for scout, r in latest.items():
    if scout != task and r['outcome'] == 'open' and isinstance(r.get('report'), str) \
            and os.path.realpath(os.path.join(root, r['report'])) in reports:
        out.append({'task': scout, 'outcome': 'done', 'at': now, 'kind': 'scout', 'followup': task})
if out:
    with open(links, 'a', encoding='utf-8') as f:
        f.write(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in out))
PY
}

case "${1:-}" in
  unowned|resolve) cmd_unowned "$@" ;;
  record-outcome) shift; cmd_record_outcome "$@" ;;
  record-close) shift; cmd_record_close "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
