#!/bin/bash
set -uo pipefail

DATA_DIR="$HOME/.claude/auto-approve"
COOLOFF_DIR="$DATA_DIR/cooloff"
COOLOFF_SECONDS=1800  # 30 minutes
USAGE_LOG="$DATA_DIR/usage.log"
TOTALS_DIR="$DATA_DIR/totals"

mkdir -p "$COOLOFF_DIR" "$TOTALS_DIR"

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

update_usage_stats() {
  (
    local PROVIDER=$1 MODEL=$2 PROMPT_TOK=$3 COMPLETION_TOK=$4 INPUT_COST=$5 OUTPUT_COST=$6 DECISION=$7 COMMAND=$8

    # Append to per-call usage log
    echo "$(date '+%Y-%m-%dT%H:%M:%S') provider=$PROVIDER model=$MODEL prompt_tokens=$PROMPT_TOK completion_tokens=$COMPLETION_TOK decision=$DECISION command=\"$COMMAND\"" >> "$USAGE_LOG"

    # Update per-provider totals
    local TOTALS_FILE="$TOTALS_DIR/$PROVIDER"
    local PREV_CALLS=0 PREV_PROMPT=0 PREV_COMPLETION=0 PREV_COST="0.00"
    if [ -f "$TOTALS_FILE" ]; then
      # shellcheck disable=SC1090
      source "$TOTALS_FILE"
      PREV_CALLS=${CALLS:-0}
      PREV_PROMPT=${PROMPT_TOKENS:-0}
      PREV_COMPLETION=${COMPLETION_TOKENS:-0}
      PREV_COST=${COST_USD:-0.00}
    fi

    local NEW_CALLS=$(( PREV_CALLS + 1 ))
    local NEW_PROMPT=$(( PREV_PROMPT + PROMPT_TOK ))
    local NEW_COMPLETION=$(( PREV_COMPLETION + COMPLETION_TOK ))
    local CALL_COST
    CALL_COST=$(awk "BEGIN { printf \"%.2f\", ($PROMPT_TOK * $INPUT_COST + $COMPLETION_TOK * $OUTPUT_COST) / 1000000 }")
    local NEW_COST
    NEW_COST=$(awk "BEGIN { printf \"%.2f\", $PREV_COST + $CALL_COST }")

    local TMPFILE="${TOTALS_FILE}.tmp.$$"
    cat > "$TMPFILE" <<EOF
CALLS=$NEW_CALLS
PROMPT_TOKENS=$NEW_PROMPT
COMPLETION_TOKENS=$NEW_COMPLETION
COST_USD=$NEW_COST
EOF
    mv "$TMPFILE" "$TOTALS_FILE"
  ) 2>/dev/null || true
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
  local TOOL_NAME TOOL_INPUT PROMPT

  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Bash"')

  case "$TOOL_NAME" in
    Bash)
      TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command')
      if [ $? -ne 0 ] || [ -z "$TOOL_INPUT" ]; then
        return 1
      fi

      PROMPT="Analyze the following bash command.

\`\`\`
$TOOL_INPUT
\`\`\`

Should a system administrator be warned before running this command?
Only answer YES for commands that could cause significant damage: deleting important data, breaking services, modifying security settings, or making irreversible system changes.
Routine operations like creating/removing temp files, installing packages, or restarting non-critical services do NOT need warnings.

Reply with exactly one word: YES or NO"
      ;;
    WebFetch)
      TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.url')
      if [ $? -ne 0 ] || [ -z "$TOOL_INPUT" ]; then
        return 1
      fi

      PROMPT="Analyze the following URL that an AI assistant wants to fetch:

$TOOL_INPUT

Is this URL potentially dangerous? Consider:
- SSRF: internal/private network addresses (127.0.0.1, 10.x, 172.16-31.x, 192.168.x, localhost, .local)
- Data exfiltration: sensitive data encoded in URL parameters
- Known malicious domains or phishing/typosquatting of popular sites

Most URLs to public websites, documentation sites, APIs, and content platforms are SAFE.

Reply with exactly one word: YES or NO"
      ;;
    *)
      return 1
      ;;
  esac

  # Try providers in order, skipping rate-limited ones
  # Replace these with your own API keys and endpoints
  local PROVIDERS=(
    "opencode|https://opencode.ai/zen/v1/chat/completions|YOUR_OPENCODE_API_KEY|kimi-k2.5-free|0|0"
    "moonshot|https://api.moonshot.ai/v1/chat/completions|YOUR_MOONSHOT_API_KEY|kimi-k2.5|0.60|3.00"
  )

  for ENTRY in "${PROVIDERS[@]}"; do
    IFS='|' read -r NAME URL KEY MODEL INPUT_COST OUTPUT_COST <<< "$ENTRY"

    if is_cooled_off "$NAME"; then
      continue
    fi

    local RESPONSE
    RESPONSE=$(call_api "$URL" "$KEY" "$MODEL" "$PROMPT")
    local EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ] || [ -z "$RESPONSE" ]; then
      continue
    fi

    # Check for rate limit or other API error
    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
      local ERROR_MSG
      ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .error // empty' 2>/dev/null)
      if echo "$ERROR_MSG" | grep -qi "rate limit"; then
        set_cooloff "$NAME"
      fi
      continue
    fi

    local CONTENT
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    # Extract token usage
    local PROMPT_TOKENS COMPLETION_TOKENS
    read -r PROMPT_TOKENS COMPLETION_TOKENS <<< \
      $(echo "$RESPONSE" | jq -r '[.usage.prompt_tokens // 0, .usage.completion_tokens // 0] | @tsv' 2>/dev/null) \
      || { PROMPT_TOKENS=0; COMPLETION_TOKENS=0; }

    if echo "$CONTENT" | grep -qiw "NO"; then
      update_usage_stats "$NAME" "$MODEL" "$PROMPT_TOKENS" "$COMPLETION_TOKENS" "$INPUT_COST" "$OUTPUT_COST" "approve" "$TOOL_INPUT"
      echo "approve"
      return 0
    elif echo "$CONTENT" | grep -qiw "YES"; then
      update_usage_stats "$NAME" "$MODEL" "$PROMPT_TOKENS" "$COMPLETION_TOKENS" "$INPUT_COST" "$OUTPUT_COST" "prompt" "$TOOL_INPUT"
      echo "prompt"
      return 0
    else
      continue
    fi
  done

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
