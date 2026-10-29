#!/usr/bin/env bash
# fm-todo-stop-check.sh - Claude Code Stop hook that refuses a firstmate
# primary's turn end while a task touched this turn is not reflected in the
# captain's notes-keeping todo list.
#
# Usage: <Stop hook JSON on stdin> | bin/fm-todo-stop-check.sh --claude
#
# Scope: a genuine primary home (fm_primary_scope_matches in
#   bin/fm-primary-scope-lib.sh), outside a task worker (FM_TASK_ID unset),
#   with an executable $FM_HOME/config/notes-keeping-bridge. Anywhere else it
#   is inert: exit 0, no output.
#
# The turn starts at the ISO-8601 time in $FM_HOME/state/jev-turn-start
# (bin/fm-jev-prompt-reminder.sh writes it at every prompt). A task is touched
# this turn when state/<id>.meta was written since then (spawn), when
# state/<id>.status has a done or blocked line stamped [at=<epoch>] since then,
# or when state/notes-todo-links.jsonl has an outcome record for it written
# since then (cleanup; bin/fm-todo-guard.sh record-outcome).
#
# For each touched task:
#   - it needs a link in state/notes-todo-links.jsonl (the latest record per
#     item key, an unlink dropping it, as the bridge reads them) or a
#     no_todo=<reason> line in its meta;
#   - each linked todo found under the Todo heading of the active notes file
#     (state/notes-keeping-active.json) must carry the task's mark: [x] once
#     the last state line is done or the task was cleaned up with outcome done,
#     [!] when it is blocked, [~] otherwise while its meta exists. A failed
#     task, a todo marked [-], and a todo not in the notes file are not checked.
#     A lagging mark passes when the bridge's status already reports the
#     matching status (the plugin writes it), or when a bridge call for it was
#     recorded this turn: a link of that task to that todo, or for [!] a block
#     record for the task.
#
# Output:
#   ALLOW - exit 0, no output.
#   BLOCK - exit 2 with one line per gap on stderr naming the task, the todo
#           id, and the bridge command to run; the turn continues.
#   FAIL OPEN - no turn start recorded, missing python3, or a bridge status
#               that fails or is not a JSON object.
set -u

[ "${1:-}" = --claude ] || [ $# -eq 0 ] || { echo "usage: fm-todo-stop-check.sh --claude < <Stop hook JSON>" >&2; exit 2; }
[ -z "${FM_TASK_ID:-}" ] || exit 0
cat > /dev/null 2>&1 || true
command -v python3 >/dev/null 2>&1 || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
export FM_HOME=${FM_HOME:-$FM_ROOT}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$FM_HOME/state" || exit 0
BRIDGE="$FM_HOME/config/notes-keeping-bridge"
[ -x "$BRIDGE" ] || exit 0
[ -s "$FM_HOME/state/jev-turn-start" ] || exit 0

python3 - "$FM_HOME/state" "$BRIDGE" <<'PY'
import calendar, glob, json, os, re, shlex, subprocess, sys, time

state, bridge = sys.argv[1], sys.argv[2]
STATE_LINE = re.compile(r'^(working|needs-decision|blocked|paused|done|failed)(?: \[([^\]]*)\])?:\s*(.*)$')
AT = re.compile(r'(?:^|\s)at=(\d+)(?:\s|$)')
ITEM_ID = re.compile(r'<!-- id:([a-z0-9]+) -->')
HEADING = re.compile(r'^(#+)\s+(.*?)\s*$')
ITEM = re.compile(r'^\s*[-*] \[(.)\] (.*?)\s*$')
LABEL = re.compile(r'^\*\*(.+?)\*\*: (.*)$')
MARK = {'done': 'x', 'blocked': '!', 'in-progress': '~'}


def read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return None


def jsonl(path):
    for line in (read(path) or '').splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            yield record


try:
    start = calendar.timegm(time.strptime(read(os.path.join(state, 'jev-turn-start')).strip(), '%Y-%m-%dT%H:%M:%SZ'))
except (AttributeError, ValueError):
    sys.exit(0)


def key_of(text):
    return ' '.join(text.lower().split())


links, outcomes = {}, {}
for r in jsonl(os.path.join(state, 'notes-todo-links.jsonl')):
    key = r.get('key')
    if isinstance(key, str):
        if r.get('unlink'):
            links.pop(key, None)
        elif isinstance(r.get('task'), str):
            links[key] = r
    elif isinstance(r.get('task'), str) and r.get('outcome') in ('done', 'failed'):
        outcomes[r['task']] = r
blocks = [r for r in jsonl(os.path.join(state, 'notes-todo-blocks.jsonl')) if isinstance(r.get('task'), str)]


def state_lines(task):
    out = []
    for line in (read(os.path.join(state, f'{task}.status')) or '').splitlines():
        m = STATE_LINE.match(line)
        if m:
            at = AT.search(m.group(2) or '')
            out.append((m.group(1), int(at.group(1)) if at else None, m.group(3)))
    return out


# task -> (expected bridge status or None, blocked reason, meta text or None)
touched = {}
for meta in glob.glob(os.path.join(state, '*.meta')):
    task = os.path.basename(meta)[:-len('.meta')]
    lines = state_lines(task)
    fresh = os.path.getmtime(meta) >= start or any(s in ('done', 'blocked') and at is not None and at >= start for s, at, _ in lines)
    if not fresh:
        continue
    last = lines[-1] if lines else ('working', None, '')
    expected = {'done': 'done', 'blocked': 'blocked', 'failed': None}.get(last[0], 'in-progress')
    touched[task] = (expected, last[2] if last[0] == 'blocked' else '', read(meta) or '')
for task, r in outcomes.items():
    if task not in touched and isinstance(r.get('at'), int) and r['at'] >= start:
        touched[task] = ('done' if r['outcome'] == 'done' else None, '', None)
if not touched:
    sys.exit(0)

marks = {}
notes = None
try:
    notes = json.loads(read(os.path.join(state, 'notes-keeping-active.json')) or 'null').get('file')
except (ValueError, AttributeError):
    pass
level = 0
for line in ((read(notes) if isinstance(notes, str) else None) or '').splitlines():
    m = HEADING.match(line)
    if m:
        if m.group(2).lower() == 'todo':
            level = len(m.group(1))
        elif level and len(m.group(1)) <= level:
            level = 0
        continue
    m = ITEM.match(line) if level else None
    if m:
        found = ITEM_ID.search(m.group(2))
        label = LABEL.match(m.group(2))
        text = label.group(2) if label else m.group(2)
        marks[f'id:{found.group(1)}' if found else key_of(text)] = m.group(1)

bridge_status = None
gaps = []
for task in sorted(touched):
    expected, reason, meta = touched[task]
    owned = [(key, r) for key, r in links.items() if r['task'] == task]
    if not owned:
        if meta is None or not re.search(r'^no_todo=\S', meta, re.M):
            gaps.append(f'{task}: no todo link and no recorded no-todo reason; link it to the todo it works on: '
                        f'{bridge} link {task} id:<todo id> --by firstmate (bin/fm-todo-guard.sh resolve "<todo text>" finds it), '
                        f'or add no_todo=<reason> to state/{task}.meta when it works on none')
        continue
    if expected is None:
        continue
    for key, r in owned:
        found = ITEM_ID.search(r.get('text') or '')
        item = f"id:{r['id']}" if isinstance(r.get('id'), str) else (f'id:{found.group(1)}' if found else key)
        mark = marks.get(item)
        if mark is None or mark == '-' or mark == MARK[expected]:
            continue
        if isinstance(r.get('at'), int) and r['at'] >= start:
            continue
        if expected == 'blocked' and any(b['task'] == task and isinstance(b.get('at'), int) and b['at'] >= start for b in blocks):
            continue
        if bridge_status is None:
            try:
                bridge_status = json.loads(subprocess.run([bridge, 'status', notes], capture_output=True, text=True,
                                                          check=True, timeout=10).stdout)
            except (OSError, ValueError, subprocess.SubprocessError):
                sys.exit(0)
            if not isinstance(bridge_status, dict):
                sys.exit(0)
        entry = bridge_status.get(item) or bridge_status.get(r.get('text') or '')
        if isinstance(entry, dict) and entry.get('status') == expected:
            continue
        todo = item[3:] if item.startswith('id:') else item
        command = (f'{bridge} block {task} --reason {shlex.quote(reason or "blocked")} --by firstmate' if expected == 'blocked'
                   else f'{bridge} link {task} {item if item.startswith("id:") else shlex.quote(r.get("text") or item)} --by firstmate')
        gaps.append(f'{task}: todo {todo} reads [{mark}] but the task is {expected}, which is [{MARK[expected]}]; run: {command}')

if gaps:
    print('[todo-status] tasks touched this turn are not reflected in the notes-keeping todo list:', file=sys.stderr)
    print('\n'.join(f'- {g}' for g in gaps), file=sys.stderr)
    sys.exit(2)
PY
