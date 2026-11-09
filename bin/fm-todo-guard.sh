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
#   fm-todo-guard.sh unowned [--notes <notes-file>]... [--note <inbox-note>]... [--like <text>]
#   fm-todo-guard.sh resolve <todo text> [--notes <notes-file>]... [--note <inbox-note>]... [--task <task-id>]
#   fm-todo-guard.sh record-outcome <task-id> [--pr <url>] [--report <path>]
#     [--scout [--report-has-captain-call <yes|no>] [--scout-recommends-ship <yes|no>]]
#   fm-todo-guard.sh record-close <task-id>
#   fm-todo-guard.sh objective <task-id> <notes-file> <text> [--ai-generated]
#   fm-todo-guard.sh link-task <task-id> [--todo <todo text>]... [--origin <task-id>]
#     [--objective <text> [--ai-generated]] [--no-todo <reason>]
#   fm-todo-guard.sh related <task-id>
#
# `unowned` prints an `UNOWNED TODOS` section listing every open item (`[ ]` or
# `[~]`) under the `Todo` heading of each notes file that no work owns, then
# exits 1; it prints nothing and exits 0 when every open item is owned.
# With --like it lists only the unowned items that plausibly are <text>: the
# item's key or label key and <text>'s key, as word sequences, contain one the
# other, or at least two significant words (three letters or more, common
# words aside) are shared and they make up at least half of the item's.
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
# exits 1. With --task, a blocked item (`[!]`) the bridge's `status` links to
# <task-id> also counts as open, because an answered or released captain hold
# can leave the item blocked while the task it held still owns it.
# When config/notes-keeping-bridge is absent it prints the text as given.
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
# backlog root) or names on a `Captain hold report:` body line, so the scout's
# todos close with the work its report left.
#
# `objective` queues <text> as firstmate's [UPDATE] in <notes-file> through the
# bridge's `update` verb, links the todo the plugin makes from it to <task-id>
# by id, and prints that id. With --ai-generated the text is written as
# `(AI-generated) <task-id>: <text>`, which marks a task firstmate started on
# its own initiative where the plugin shows objectives; without it,
# `<task-id>: <text>`. A failed update exits 1 with the bridge's reason.
# Without --ai-generated the task serves a captain ask, whose todo belongs on
# the captain's list: while `unowned --notes <notes-file> --like <text>` lists
# an open item that plausibly is this ask, it queues nothing and exits 1 with
# that list, so the existing item is linked with --todo instead of duplicated;
# unowned items unrelated to the ask do not stop it.
#
# `link-task` makes sure <task-id> ends up linked to a todo, and refuses when
# it cannot. Each --todo is resolved as `resolve` does and linked, by id when
# its line ends in the plugin's `<!-- id:<id> -->` comment. A task the bridge
# already links passes. With --origin, an item linked to that origin passes the
# task when the bridge reports it in-progress (the origin still owns it), and
# moves to the task when the bridge reports it null or blocked (the origin ended
# without landing it, such as a scout whose report left work). Still unlinked,
# --objective runs `objective` against the notes file the bridge's `active`
# names. Still unlinked, --no-todo <reason> passes only while no notes-keeping
# session is active. Anything else exits 1 naming what to pass. It prints one
# line per link it makes or relies on. --todo contradicts --objective and
# --no-todo, and --ai-generated needs --objective.
#
# `related` prints a RELATED TODOS section naming work whose todos may need to
# change with <task-id>'s: tasks an item linked to <task-id> was linked to
# before or after, and tasks that record the same PR, from the outcome records
# and state/*.meta `pr=` lines. It changes nothing: the bridge already derives
# every item's status from its latest link, so no other change is mechanical.
# `record-outcome` prints it after the outcome it records.
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
  local query='' like='' task='' notes=() records=() status_json='{}'
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
      --like) [ -z "$query" ] || die "--like filters unowned"; { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--like needs a text"; like=$2; shift 2 ;;
      --task) [ -n "$query" ] || die "--task belongs to resolve"; { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--task needs a task id"; task=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [ ! -x "$BRIDGE" ]; then
    [ -z "$query" ] || printf '%s\n' "$query"
    return 0
  fi
  { [ -n "$query" ] && [ -z "$task" ]; } || status_json=$(FM_HOME="$FM_HOME" "$BRIDGE" status "${notes[0]:-.}") \
    || die "the bridge's status failed: $BRIDGE"
  FM_TODO_STATUS="$status_json" FM_TODO_QUERY="$query" FM_TODO_LIKE="$like" FM_TODO_TASK="$task" python3 - "$STATE/inbox" "$SELF_DIR/fm-tasks-axi.sh" \
    "${#notes[@]}" ${notes[@]+"${notes[@]}"} ${records[@]+"${records[@]}"} <<'PY'
import json, os, re, subprocess, sys, time

inbox, tasks_axi, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
notes = sys.argv[4:4 + count]
records = sys.argv[4 + count:]
query = os.environ['FM_TODO_QUERY']
like = os.environ['FM_TODO_LIKE']
task = os.environ['FM_TODO_TASK']
WINDOW = 3 * 86400
CHANGED = re.compile(r'^notes-keeping todo changed in (.+):$')
HEADING = re.compile(r'^(#+)\s+(.*?)\s*$')
ITEM = re.compile(r'^\s*[-*] \[([ ~!])\] (.*?)\s*$')
ITEM_ID = re.compile(r'<!-- id:([a-z0-9]+) -->$')
COMMON = {'the', 'and', 'for', 'with', 'this', 'that', 'from', 'into', 'onto', 'our', 'your', 'you', 'are', 'was',
          'were', 'has', 'have', 'had', 'not', 'but', 'all', 'can', 'its', 'out', 'off', 'about', 'please', 'need',
          'needs', 'want', 'should', 'would', 'could', 'will', 'just', 'then', 'them', 'they', 'what', 'when'}
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


def owned_by_task(text):
    m = ITEM_ID.search(text)
    entry = links.get(f'id:{m.group(1)}') if m else None
    entry = entry or links.get(key_of(ITEM_ID.sub('', text)))
    return bool(task) and isinstance(entry, dict) and entry.get('task') == task


def words(text):
    return {w for w in re.findall(r'[a-z0-9]+', ITEM_ID.sub('', text).lower()) if len(w) >= 3 and w not in COMMON}


def plausibly(text, label):
    want, want_words = f' {key_of(ITEM_ID.sub("", like))} ', words(like)
    for candidate in [text] + ([label] if label else []):
        key = f' {key_of(ITEM_ID.sub("", candidate))} '
        if key.strip() and (key in want or want in key):
            return True
        have = words(candidate)
        shared = len(have & want_words)
        if shared >= 2 and 2 * shared >= len(have):
            return True
    return False


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
            text = label.group(2) if label else m.group(2)
            if m.group(1) != '!' or owned_by_task(text):
                yield m.group(1), text, (label.group(1) if label else None)


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
        if like and not plausibly(text, label):
            continue
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
  cmd_related "$task"
}

bridge() { FM_HOME="$FM_HOME" "$BRIDGE" "$@"; }

cmd_objective() {  # <task-id> <notes-file> <text> [--ai-generated]
  local task=${1:-} file=${2:-} text=${3:-} mark='' id
  [ -n "$task" ] && [ -n "$file" ] && [ -n "$text" ] \
    || die "usage: fm-todo-guard.sh objective <task-id> <notes-file> <text> [--ai-generated]"
  case "${4:-}" in
    '') ;;
    --ai-generated) mark='(AI-generated) ' ;;
    *) die "unknown argument: $4" ;;
  esac
  if [ -z "$mark" ]; then
    local open rc=0
    open=$(cmd_unowned unowned --notes "$file" --like "$text") || rc=$?
    [ "$rc" -eq 0 ] || {
      printf "fm-todo-guard: %s serves a captain ask; link the captain's existing todo with --todo \"<todo text>\" instead of queuing a duplicate objective\n%s\n" \
        "$task" "$open" >&2
      return 1
    }
  fi
  id=$(bridge update "$file" "$mark$task: $text" --by firstmate --task "$task" 2>&1) || {
    printf '%s\n' "$id" >&2
    return 1
  }
  bridge link "$task" "id:$id" --by firstmate \
    || printf 'fm-todo-guard: warning: could not link todo id:%s to %s through %s\n' "$id" "$task" "$BRIDGE" >&2
  printf '%s\n' "$id"
}

# Prints "<status>\t<key>" for each item the bridge links to <task-id>.
linked_to() {  # <status-json> <task-id>
  python3 -c '
import json, sys
for key, entry in json.loads(sys.argv[1]).items():
    if isinstance(entry, dict) and entry.get("task") == sys.argv[2]:
        print((entry.get("status") or "null") + "\t" + key)
' "$1" "$2"
}

cmd_link_task() {
  local task=${1:-} origin='' objective='' ai='' no_todo='' no_todo_set=0 todo item status status_json rows session made=0
  local todos=()
  [ -n "$task" ] || die "usage: fm-todo-guard.sh link-task <task-id> [--todo <text>]... [--origin <task-id>] [--objective <text> [--ai-generated]] [--no-todo <reason>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --todo) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--todo needs a todo text"; todos+=("$2"); shift 2 ;;
      --origin) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--origin needs a task id"; origin=$2; shift 2 ;;
      --objective) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--objective needs a text"; objective=$2; shift 2 ;;
      --ai-generated) ai=--ai-generated; shift ;;
      --no-todo) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "--no-todo needs a reason"; no_todo=$2; no_todo_set=1; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ "${#todos[@]}" -eq 0 ] || { [ -z "$objective" ] && [ "$no_todo_set" -eq 0 ]; } \
    || die "--todo names a captain todo; it contradicts --objective and --no-todo"
  [ -z "$ai" ] || [ -n "$objective" ] || die "--ai-generated marks an --objective; pass one"
  [ -z "$objective" ] || [ "$no_todo_set" -eq 0 ] || die "--objective and --no-todo contradict each other; pass one"
  [ -x "$BRIDGE" ] || return 0
  for todo in ${todos[@]+"${todos[@]}"}; do
    item=$(cmd_unowned resolve "$todo") || {
      printf 'fm-todo-guard: --todo for %s must name exactly one open todo; nothing was linked\n%s\n' "$task" "$item" >&2
      return 1
    }
    if [[ $item =~ ^(.*[^[:space:]])[[:space:]]*'<!-- id:'([a-z0-9]+)' -->'$ ]]; then
      item=id:${BASH_REMATCH[2]}
    fi
    bridge link "$task" "$item" --by firstmate || die "the bridge could not link '$item' to $task"
    printf 'linked %s: %s\n' "$task" "$item"
    made=1
  done
  [ "$made" -eq 0 ] || return 0
  status_json=$(bridge status .) || die "the bridge's status failed: $BRIDGE"
  rows=$(linked_to "$status_json" "$task") || die "the bridge status is not a JSON object"
  if [ -n "$rows" ]; then
    while IFS=$'\t' read -r _ item; do printf 'linked %s: %s\n' "$task" "$item"; done <<< "$rows"
    return 0
  fi
  if [ -n "$origin" ]; then
    rows=$(linked_to "$status_json" "$origin") || die "the bridge status is not a JSON object"
    while IFS=$'\t' read -r status item; do
      case "$status" in
        in-progress) printf 'covered %s: %s (its origin %s still owns it)\n' "$task" "$item" "$origin"; made=1 ;;
        null|blocked)
          bridge link "$task" "$item" --by firstmate || die "the bridge could not link '$item' to $task"
          printf 'linked %s: %s (moved from its origin %s)\n' "$task" "$item" "$origin"
          made=1
          ;;
      esac
    done <<< "$rows"
    [ "$made" -eq 0 ] || return 0
  fi
  session=$(bridge active 2>/dev/null) || session=
  if [ -n "$objective" ]; then
    [ -n "$session" ] || {
      printf 'fm-todo-guard: no notes-keeping session is active to take the objective for %s; pass --todo "<todo text>", or --no-todo "<reason>"\n' "$task" >&2
      return 1
    }
    item=$(cmd_objective "$task" "$session" "$objective" $ai) || {
      printf 'fm-todo-guard: %s: could not add its notes-keeping objective update\n' "$task" >&2
      return 1
    }
    printf 'linked %s: id:%s (objective%s)\n' "$task" "$item" "${ai:+, AI-generated}"
    return 0
  fi
  if [ "$no_todo_set" -eq 1 ] && [ -z "$session" ]; then
    printf 'no todo %s: %s\n' "$task" "$no_todo"
    return 0
  fi
  printf 'fm-todo-guard: %s has no notes-keeping todo linked; pass --todo "<todo text>" naming the captain todo it serves, --objective "<text>" (with --ai-generated when firstmate started it on its own initiative), or --no-todo "<reason>" while no notes-keeping session is active\n' "$task" >&2
  cmd_unowned unowned >&2 || true
  return 1
}

cmd_related() {  # <task-id>
  local task=${1:-}
  [ -n "$task" ] || die "usage: fm-todo-guard.sh related <task-id>"
  [ -f "$STATE/notes-todo-links.jsonl" ] || return 0
  python3 - "$STATE" "$task" <<'PY'
import glob, json, os, sys

state, task = sys.argv[1:3]
history, prs = {}, {}
with open(os.path.join(state, 'notes-todo-links.jsonl'), encoding='utf-8', errors='replace') as f:
    for line in f:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict) or not isinstance(r.get('task'), str):
            continue
        if isinstance(r.get('key'), str) and not r.get('unlink'):
            tasks = history.setdefault(r['key'], [])
            if not tasks or tasks[-1] != r['task']:
                tasks.append(r['task'])
        if isinstance(r.get('pr'), str) and r['pr']:
            prs.setdefault(r['pr'], set()).add(r['task'])
for meta in glob.glob(os.path.join(state, '*.meta')):
    try:
        with open(meta, encoding='utf-8', errors='replace') as f:
            for line in f:
                if line.startswith('pr=') and line[3:].strip():
                    prs.setdefault(line[3:].strip(), set()).add(os.path.basename(meta)[:-len('.meta')])
    except OSError:
        continue
out = []
for key, tasks in history.items():
    if task not in tasks:
        continue
    for other in dict.fromkeys(tasks):
        if other != task:
            now = 'now linked to it' if tasks[-1] == other else f'now linked to {tasks[-1]}'
            out.append(f'- {other}: shares todo {key} ({now})')
for url, tasks in prs.items():
    if task in tasks:
        out.extend(f'- {other}: records the same PR {url}' for other in sorted(tasks - {task}))
if out:
    print(f"RELATED TODOS (work whose todos may need to change with {task}'s; check each, nothing was changed):")
    print('\n'.join(dict.fromkeys(out)))
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
m = re.search(r'^\s*body: (.*?)\s*$', os.environ['FM_TODO_SHOW'], re.M)
body = (json.loads(m.group(1)) if m.group(1).startswith('"') else m.group(1)) if m else ''
for line in body.split('\n'):
    if line.startswith('Captain hold report: ') and line[21:].strip():
        reports.add(os.path.realpath(os.path.join(root, line[21:].strip())))
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
  objective) shift; cmd_objective "$@" ;;
  link-task) shift; cmd_link_task "$@" ;;
  related) shift; cmd_related "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
