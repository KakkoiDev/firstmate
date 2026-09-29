#!/usr/bin/env bash
# Token-free live guard for the tracked Jev hooks under the installed Claude
# Code: the UserPromptSubmit turn start (bin/fm-jev-prompt-reminder.sh), the
# PreToolUse guard (bin/fm-jev-pretool-check.sh), and the Stop check
# (bin/fm-jev-stop-check.sh).
#
# The verdict depends on vendor surfaces a stub cannot confirm: that Claude
# runs the tracked commands, that the "Bash|mcp__.*" matcher reaches an MCP
# tool, that an exit-2 PreToolUse refusal keeps the tool from running and
# reaches the model, and that an exit-2 Stop refusal continues the turn with
# its reason. So the real claude runs against a local fake Anthropic endpoint
# (ANTHROPIC_BASE_URL) that scripts every model turn from the conversation it
# is sent, with a fake Notion MCP server and a fake Jev endpoint. No model
# token is spent, so it runs by default wherever claude and python3 are
# installed.
#
# The scripted turn: a Notion status write (refused: it needs a claim-check),
# a Bash command switching off an action script's gate (refused), a bound
# claim-check ask, the same Notion write (allowed and run), an ask-scope ask
# that disagrees with Jev, then three final messages: a bare one (refused: no
# section), one with the section (refused: the disagreement is unmentioned),
# and one that also names the disagreement (the turn ends).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_JEV_CLAUDE_HOOKS_LIVE claude python3

CLAUDE_BIN=$(command -v claude)
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-jev-claude-hooks-live)
LAB="$TMP_ROOT/lab"
FAKE="$TMP_ROOT/fake"
REQ_LOG="$TMP_ROOT/requests.jsonl"
MCP_LOG="$TMP_ROOT/mcp-calls.jsonl"
PORT_FILE="$TMP_ROOT/port"
SOURCE_FILE="$FAKE/pr-view.txt"
PAGE_UUID='26ab1f9f-4c5f-80b1-8d3b-d10a6b1d2f4e'
SERVER_PID=''
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$LAB/state" "$LAB/.claude" "$FAKE" "$TMP_ROOT/claude-config"
cp -R "$ROOT/bin" "$LAB/bin"
printf '# lab\n' > "$LAB/AGENTS.md"
git -C "$LAB" init -q
printf '%s\n' 'state:   MERGED' > "$SOURCE_FILE"
# Only the tracked Jev entries, copied from the tracked settings.
jq '{hooks: {
    UserPromptSubmit: [{hooks: [.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("/bin/fm-jev-"))]}],
    PreToolUse: [.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("/bin/fm-jev-")))],
    Stop: [{hooks: [.hooks.Stop[].hooks[] | select(.command | contains("/bin/fm-jev-"))]}]}}' \
  "$ROOT/.claude/settings.json" > "$LAB/.claude/settings.json"
[ "$(jq '[.hooks[][].hooks[]] | length' "$LAB/.claude/settings.json")" = 3 ] \
  || fail "the tracked settings do not carry the three Jev hook entries: $(cat "$LAB/.claude/settings.json")"

# The fake Jev endpoint: a claim-check request gets supported, any other gets
# login, so the ask-scope below disagrees with firstmate's signup.
jq -n '{model: "jev-1.13.0", answers: {q: {type: "choice", choice: "supported", confidence: 0.9,
  probabilities: {supported: 0.9, contradicted: 0.05, "not-addressed": 0.05}}}, usage: {input_tokens: 300, output_tokens: 40}}' \
  > "$FAKE/claim.json"
jq -n '{model: "jev-1.13.0", answers: {q: {type: "choice", choice: "login", confidence: 0.8,
  probabilities: {login: 0.8, signup: 0.1, several: 0.05, unclear: 0.05}}}, usage: {input_tokens: 300, output_tokens: 40}}' \
  > "$FAKE/scope.json"
cat > "$FAKE/curl" <<SH
#!/usr/bin/env bash
out=''
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac; done
if grep -q '"not-addressed"'; then cp '$FAKE/claim.json' "\$out"; else cp '$FAKE/scope.json' "\$out"; fi
printf 200
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/claude"
chmod +x "$FAKE/curl" "$FAKE/claude"

cat > "$FAKE/notion_mcp.py" <<'PY'
import json, sys
log = sys.argv[1]
tools = [{"name": "notion-update-page", "description": "Update a Notion page.",
          "inputSchema": {"type": "object", "properties": {"page_id": {"type": "string"}, "properties": {"type": "object"}},
                          "required": ["page_id"]}}]
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "tools/call":
        with open(log, "a") as f:
            f.write(json.dumps(msg.get("params")) + "\n")
    if mid is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake-notion", "version": "0.0.1"}}
    elif method == "tools/list":
        result = {"tools": tools}
    elif method == "tools/call":
        result = {"content": [{"type": "text", "text": "fake-notion-updated"}]}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()
PY
jq -n --arg py "$FAKE/notion_mcp.py" --arg log "$MCP_LOG" \
  '{mcpServers: {notion: {type: "stdio", command: "python3", args: [$py, $log]}}}' > "$FAKE/mcp.json"

cat > "$FAKE/anthropic.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log, port_file, source, page = sys.argv[1:5]
claim = ("bin/fm-jev.sh ask --template claim-check --target notion:%s --claim 'PR 42 is merged.' "
         "--source %s --evidence 'state: MERGED' --mine supported") % (page, source)
scope = ("bin/fm-jev.sh ask --template ask-scope --words 'fix the login flake' "
         "--candidate login --candidate signup --mine signup")

def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from strings(x)

def section(text):
    lines, out = text.splitlines(), []
    for i, line in enumerate(lines):
        if line.startswith("Jev asks this turn ("):
            out = [line] + [m for m in lines[i + 1:i + 10] if m.startswith("firstmate ")]
    return "\n".join(out)

def plan(body):
    text = "\n".join(strings(body.get("messages") or []))
    if not body.get("tools"):
        return "aside", ("text", "ok")
    if "firstmate disagreed with Jev" in text:
        return "final-mention", ("text", "Fixed the login flake.\nJev answered login on the ask-scope; I disagree, "
                                 "because the operator named signup.\n\n" + section(text))
    if "[jev-turn]" in text:
        return "final-section", ("text", "Fixed the login flake.\n\n" + section(text))
    if text.count("decision_id:") >= 2:
        return "final-bare", ("text", "Fixed the login flake.")
    if "fake-notion-updated" in text:
        return "ask-scope", ("bash", scope)
    if "decision_id:" in text:
        return "notion-retry", ("notion", None)
    if "[jev-gate]" in text:
        return "claim-check", ("bash", claim)
    if "[jev-ask]" in text:
        return "gate-off", ("bash", "FM_JEV_GATE=off bin/fm-send.sh t1 hi")
    return "notion", ("notion", None)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply({})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        if not self.path.startswith("/v1/messages") or "count_tokens" in self.path:
            return self.reply({"input_tokens": 10})
        stage, (kind, value) = plan(body)
        text = "\n".join(strings(body.get("messages") or []))
        with open(log, "a") as f:
            f.write(json.dumps({"stage": stage, "text": text}) + "\n")
        if kind == "bash":
            block = {"type": "tool_use", "id": "toolu_" + stage, "name": "Bash", "input": {"command": value, "description": stage}}
        elif kind == "notion":
            name = next(t["name"] for t in body["tools"] if t.get("name", "").endswith("notion-update-page"))
            block = {"type": "tool_use", "id": "toolu_" + stage, "name": name,
                     "input": {"page_id": page, "properties": {"Status": "Merged"}}}
        else:
            block = {"type": "text", "text": value}
        stop = "end_turn" if kind == "text" else "tool_use"
        usage = {"input_tokens": 10, "output_tokens": 5}
        message = {"id": "msg_" + stage, "type": "message", "role": "assistant", "model": body.get("model", "claude"),
                   "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}
        if not body.get("stream"):
            message.update(content=[block], stop_reason=stop)
            return self.reply(message)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        def event(name, data):
            data["type"] = name
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode())
        event("message_start", {"message": message})
        if kind == "text":
            event("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}})
            event("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": value}})
        else:
            event("content_block_start", {"index": 0, "content_block": dict(block, input={})})
            event("content_block_delta", {"index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}})
        event("content_block_stop", {"index": 0})
        event("message_delta", {"delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
        event("message_stop", {})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$FAKE/anthropic.py" "$REQ_LOG" "$PORT_FILE" "$SOURCE_FILE" "$PAGE_UUID" 2> "$TMP_ROOT/server.err" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
[ -s "$PORT_FILE" ] || fail "the fake Anthropic endpoint did not start: $(cat "$TMP_ROOT/server.err")"

code=0
(
  cd "$LAB" || exit 1
  exec env -u FM_TASK_ID -u FM_HOME -u FM_JEV_HOME -u FM_ROOT_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ID -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u DD_API_KEY \
    PATH="$FAKE:$PATH" CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config" \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$PORT_FILE")" ANTHROPIC_API_KEY=sk-ant-fake-live-guard \
    TYPESAFE_API_KEY=fake-jev-live-guard CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
    FM_JEV_GATE=on FM_JEV_TRANSCRIPT_WAIT=0 \
    perl -e 'alarm 180; exec @ARGV' "$CLAUDE_BIN" -p 'fix the login flake' --setting-sources project \
    --strict-mcp-config --mcp-config "$FAKE/mcp.json" --allowedTools 'Bash,mcp__notion__notion-update-page' \
    --output-format json
) > "$TMP_ROOT/claude.json" 2> "$TMP_ROOT/claude.err" || code=$?

[ "$code" -eq 0 ] || fail "claude $CLAUDE_VERSION exited $code: $(tail -5 "$TMP_ROOT/claude.err")"
stages=$(jq -r 'select(.stage != "aside") | .stage' "$REQ_LOG" | paste -sd' ' -)
assert_equals 'notion gate-off claim-check notion-retry ask-scope final-bare final-section final-mention' "$stages" \
  "claude $CLAUDE_VERSION: the scripted turn ran every step in order"
stage_text() { jq -r --arg s "$1" 'select(.stage == $s) | .text' "$REQ_LOG"; }
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$LAB/state/jev-turn-start" \
  || fail "claude $CLAUDE_VERSION did not run the tracked UserPromptSubmit entry that records the turn start"
pass "claude $CLAUDE_VERSION runs the tracked prompt entry, which records the turn start"

assert_contains "$(stage_text gate-off)" "[jev-ask] this mcp__notion__notion-update-page call asserts a state" \
  "claude $CLAUDE_VERSION: the Notion refusal reached the model"
assert_contains "$(stage_text claim-check)" "[jev-gate] this command sets FM_JEV_GATE beside an action script" \
  "claude $CLAUDE_VERSION: the Bash refusal reached the model"
calls=$(grep -c . "$MCP_LOG" 2>/dev/null) || calls=0
assert_equals 1 "$calls" "claude $CLAUDE_VERSION: only the Notion write made after the bound claim-check reached the MCP server"
assert_equals "$PAGE_UUID" "$(jq -r .arguments.page_id "$MCP_LOG")" "claude $CLAUDE_VERSION: the allowed write is the refused one, retried"
pass "claude $CLAUDE_VERSION runs the tracked PreToolUse guard on Bash and MCP tools; a refused call never runs, and a bound claim-check lets it through"

assert_contains "$(stage_text final-section)" "[jev-turn] this turn made Jev asks, and the final message lacks" \
  "claude $CLAUDE_VERSION: the missing-section refusal reached the model"
assert_contains "$(stage_text final-mention)" "firstmate disagreed with Jev this turn (ask-scope)" \
  "claude $CLAUDE_VERSION: the unmentioned-disagreement refusal reached the model"
result=$(jq -r .result "$TMP_ROOT/claude.json")
assert_contains "$result" "firstmate claim-check: PR 42 is merged. - jev supported (0.9), mine supported" \
  "claude $CLAUDE_VERSION: the ending message carries the claim-check line"
assert_contains "$result" "firstmate ask-scope: fix the login flake - jev login (0.8), mine signup [DISAGREE]" \
  "claude $CLAUDE_VERSION: the ending message carries the disagreement line"
pass "claude $CLAUDE_VERSION runs the tracked Stop check, which continues the turn until the section and the disagreement are in the final message"
