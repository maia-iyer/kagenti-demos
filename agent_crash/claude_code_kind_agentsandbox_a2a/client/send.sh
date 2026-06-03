#!/usr/bin/env bash
# Send a single A2A message/send to the port-forwarded server and print the
# assistant's text reply. Assumes `kubectl port-forward svc/claude-crash-demo-a2a
# 8000:8000` is running in another terminal.
#
# Usage: ./send.sh "your prompt here"
#        A2A_URL=http://host:port ./send.sh "..."

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 \"<prompt>\"" >&2
  exit 2
fi

prompt="$1"
url="${A2A_URL:-http://localhost:8000/}"

# JSON-RPC message/send envelope. The id/messageId fields are arbitrary strings
# unique per call; using $$ keeps them distinct without pulling in uuid tooling.
req_id="cli-$$-$(date +%s 2>/dev/null || echo 0)"
msg_id="msg-$$-$(date +%s 2>/dev/null || echo 0)"

payload=$(cat <<JSON
{
  "jsonrpc": "2.0",
  "id": "$req_id",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "messageId": "$msg_id",
      "parts": [
        {"kind": "text", "text": $(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}
      ]
    }
  }
}
JSON
)

resp=$(curl -sS -X POST "$url" \
  -H 'Content-Type: application/json' \
  -d "$payload")

echo "$resp" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if "error" in data:
    print("A2A error:", json.dumps(data["error"], indent=2), file=sys.stderr)
    sys.exit(1)
result = data.get("result", {})
# Result is a Task; pull artifact text parts.
artifacts = result.get("artifacts", [])
parts = []
for a in artifacts:
    for p in a.get("parts", []):
        if p.get("kind") == "text" or "text" in p:
            parts.append(p.get("text", ""))
print("\n".join(parts) if parts else json.dumps(result, indent=2))
'
