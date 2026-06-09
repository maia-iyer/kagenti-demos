#!/usr/bin/env bash
# Send a single SendMessage RPC to the port-forwarded A2A server and print
# the assistant's text reply. Assumes
#   `kubectl port-forward svc/claude-crash-demo-a2a 8000:8000`
# is running in another terminal.
#
# a2a-sdk 1.x uses gRPC-style JSON-RPC method names ("SendMessage", not
# "message/send") with proto-shaped params.
#
# The server keys Claude Code sessions on A2A `contextId`, so passing the
# same id across calls continues one conversation, and different ids open
# parallel conversations on the same pod.
#
# Usage: ./send.sh "your prompt here"
#        A2A_CONTEXT_ID=ctx-alpha ./send.sh "..."
#        A2A_URL=http://host:port ./send.sh "..."

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 \"<prompt>\"" >&2
  exit 2
fi

prompt="$1"
url="${A2A_URL:-http://localhost:8000/}"
context_id="${A2A_CONTEXT_ID:-default}"

req_id="cli-$$-$(date +%s 2>/dev/null || echo 0)"
msg_id="msg-$$-$(date +%s 2>/dev/null || echo 0)"

# Encode the prompt as a JSON string via python so embedded quotes/newlines
# don't break the payload.
escaped_prompt=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
escaped_context=$(printf '%s' "$context_id" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

payload=$(cat <<JSON
{
  "jsonrpc": "2.0",
  "id": "$req_id",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "$msg_id",
      "contextId": $escaped_context,
      "role": "ROLE_USER",
      "parts": [
        {"text": $escaped_prompt}
      ]
    }
  }
}
JSON
)

resp=$(curl -sS -X POST "$url" \
  -H 'Content-Type: application/json' \
  -H 'A2A-Version: 1.0' \
  -d "$payload")

echo "$resp" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if "error" in data:
    print("A2A error:", json.dumps(data["error"], indent=2), file=sys.stderr)
    sys.exit(1)

# SendMessageResponse is a oneof: {"task": Task} or {"message": Message}.
result = data.get("result", {})
parts = []

if "task" in result:
    for art in result["task"].get("artifacts", []):
        for p in art.get("parts", []):
            if "text" in p:
                parts.append(p["text"])
elif "message" in result:
    for p in result["message"].get("parts", []):
        if "text" in p:
            parts.append(p["text"])

if parts:
    print("\n".join(parts))
else:
    print(json.dumps(result, indent=2))
'
