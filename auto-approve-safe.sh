#!/bin/bash
set -uo pipefail

LOG="/tmp/auto-approve-safe.log"
COOLOFF_DIR="/tmp/auto-approve-cooloff"
COOLOFF_SECONDS=1800  # 30 minutes

mkdir -p "$COOLOFF_DIR"

INPUT=$(cat)

is_cooled_off() {
  local PROVIDER=$1
  local FILE="$COOLOFF_DIR/$PROVIDER"
  if [ -f "$FILE" ]; then
    local EXPIRES
    EXPIRES=$(cat "$FILE")
    local NOW
    NOW=$(date +%s)
    if [ "$NOW" -lt "$EXPIRES" ]; then
      return 0  # still in cooloff
    fi
    rm -f "$FILE"
  fi
  return 1  # not in cooloff
}

set_cooloff() {
  local PROVIDER=$1
  local EXPIRES=$(( $(date +%s) + COOLOFF_SECONDS ))
  echo "$EXPIRES" > "$COOLOFF_DIR/$PROVIDER"
}

call_api() {
  local URL=$1 KEY=$2 MODEL=$3 PROMPT=$4

  curl -s --max-time 5 "$URL" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$MODEL" --arg prompt "$PROMPT" '{
      model: $model,
      messages: [{"role": "user", "content": $prompt}],
      max_tokens: 8,
      temperature: 0.6,
      thinking: {"type": "disabled"}
    }')" 2>/dev/null
}

classify() {
  local TOOL_INPUT PROMPT

  TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command')
  if [ $? -ne 0 ] || [ -z "$TOOL_INPUT" ]; then
    echo "jq failed or empty command" >>"$LOG"
    return 1
  fi

  echo "$(date '+%H:%M:%S') classifying: $TOOL_INPUT" >>"$LOG"

  PROMPT="Analyze the following bash command.

\`\`\`
$TOOL_INPUT
\`\`\`

Should a system administrator be warned before running this command?
Only answer YES for commands that could cause significant damage: deleting important data, breaking services, modifying security settings, or making irreversible system changes.
Routine operations like creating/removing temp files, installing packages, or restarting non-critical services do NOT need warnings.

Reply with exactly one word: YES or NO"

  # Try providers in order, skipping rate-limited ones
  # Replace these with your own API keys and endpoints
  local PROVIDERS=(
    "moonshot|https://api.moonshot.ai/v1/chat/completions|YOUR_MOONSHOT_API_KEY|kimi-k2.5"
    "opencode|https://opencode.ai/zen/v1/chat/completions|YOUR_OPENCODE_API_KEY|kimi-k2.5-free"
  )

  for ENTRY in "${PROVIDERS[@]}"; do
    IFS='|' read -r NAME URL KEY MODEL <<< "$ENTRY"

    if is_cooled_off "$NAME"; then
      echo "  $NAME: skipped (cooloff)" >>"$LOG"
      continue
    fi

    local RESPONSE
    RESPONSE=$(call_api "$URL" "$KEY" "$MODEL" "$PROMPT")
    local EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ] || [ -z "$RESPONSE" ]; then
      echo "  $NAME: timeout/error" >>"$LOG"
      continue
    fi

    # Check for rate limit or other API error
    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
      local ERROR_MSG
      ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .error // empty' 2>/dev/null)
      echo "  $NAME: error: $ERROR_MSG" >>"$LOG"
      if echo "$ERROR_MSG" | grep -qi "rate limit"; then
        set_cooloff "$NAME"
        echo "  $NAME: cooloff set for ${COOLOFF_SECONDS}s" >>"$LOG"
      fi
      continue
    fi

    local CONTENT
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    echo "  $NAME said: $CONTENT" >>"$LOG"

    if echo "$CONTENT" | grep -qiw "NO"; then
      echo "  -> approve" >>"$LOG"
      echo "approve"
      return 0
    elif echo "$CONTENT" | grep -qiw "YES"; then
      echo "  -> prompt" >>"$LOG"
      echo "prompt"
      return 0
    else
      echo "  $NAME: unrecognized response" >>"$LOG"
      continue
    fi
  done

  echo "  all providers failed" >>"$LOG"
  return 1
}

DECISION=$(classify || echo "prompt")

if [ "$DECISION" = "approve" ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: {
        behavior: "allow"
      }
    }
  }'
fi
# For "prompt" or errors: exit 0 with no output → normal permission prompt
