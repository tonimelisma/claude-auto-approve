#!/bin/bash
set -uo pipefail

LOG="/tmp/auto-approve-safe.log"
COOLOFF_DIR="/tmp/auto-approve-cooloff"
COOLOFF_SECONDS=1800  # 30 minutes
USAGE_LOG="/tmp/auto-approve-usage.log"
USAGE_TOTALS="/tmp/auto-approve-usage-totals"

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

update_usage_stats() {
  (
    local PROVIDER=$1 MODEL=$2 PROMPT_TOK=$3 COMPLETION_TOK=$4 TOTAL_TOK=$5 INPUT_COST=$6 OUTPUT_COST=$7

    # Per-call cost: (prompt_tokens * input_cost + completion_tokens * output_cost) / 1_000_000
    local CALL_COST
    CALL_COST=$(awk "BEGIN { printf \"%.6f\", ($PROMPT_TOK * $INPUT_COST + $COMPLETION_TOK * $OUTPUT_COST) / 1000000 }")

    # Append to per-call usage log
    echo "$(date '+%Y-%m-%dT%H:%M:%S') $PROVIDER $MODEL prompt=$PROMPT_TOK completion=$COMPLETION_TOK total=$TOTAL_TOK cost=\$$CALL_COST" >> "$USAGE_LOG"

    # Update running totals atomically
    local PREV_CALLS=0 PREV_PROMPT=0 PREV_COMPLETION=0 PREV_COST="0.000000"
    if [ -f "$USAGE_TOTALS" ]; then
      # shellcheck disable=SC1090
      source "$USAGE_TOTALS"
      PREV_CALLS=${TOTAL_CALLS:-0}
      PREV_PROMPT=${TOTAL_PROMPT_TOKENS:-0}
      PREV_COMPLETION=${TOTAL_COMPLETION_TOKENS:-0}
      PREV_COST=${TOTAL_COST_USD:-0.000000}
    fi

    local NEW_CALLS=$(( PREV_CALLS + 1 ))
    local NEW_PROMPT=$(( PREV_PROMPT + PROMPT_TOK ))
    local NEW_COMPLETION=$(( PREV_COMPLETION + COMPLETION_TOK ))
    local NEW_COST
    NEW_COST=$(awk "BEGIN { printf \"%.6f\", $PREV_COST + $CALL_COST }")

    local TMPFILE="${USAGE_TOTALS}.tmp.$$"
    cat > "$TMPFILE" <<EOF
TOTAL_CALLS=$NEW_CALLS
TOTAL_PROMPT_TOKENS=$NEW_PROMPT
TOTAL_COMPLETION_TOKENS=$NEW_COMPLETION
TOTAL_COST_USD=$NEW_COST
EOF
    mv "$TMPFILE" "$USAGE_TOTALS"
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
    "opencode|https://opencode.ai/zen/v1/chat/completions|YOUR_OPENCODE_API_KEY|kimi-k2.5-free|0|0"
    "moonshot|https://api.moonshot.ai/v1/chat/completions|YOUR_MOONSHOT_API_KEY|kimi-k2.5|0.60|3.00"
  )

  for ENTRY in "${PROVIDERS[@]}"; do
    IFS='|' read -r NAME URL KEY MODEL INPUT_COST OUTPUT_COST <<< "$ENTRY"

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

    # Extract token usage
    local PROMPT_TOKENS COMPLETION_TOKENS TOTAL_TOKENS
    read -r PROMPT_TOKENS COMPLETION_TOKENS TOTAL_TOKENS <<< \
      $(echo "$RESPONSE" | jq -r '[.usage.prompt_tokens // 0, .usage.completion_tokens // 0, .usage.total_tokens // 0] | @tsv' 2>/dev/null) \
      || { PROMPT_TOKENS=0; COMPLETION_TOKENS=0; TOTAL_TOKENS=0; }

    local CALL_COST
    CALL_COST=$(awk "BEGIN { printf \"%.6f\", ($PROMPT_TOKENS * $INPUT_COST + $COMPLETION_TOKENS * $OUTPUT_COST) / 1000000 }" 2>/dev/null) || CALL_COST="0.000000"

    echo "  $NAME said: $CONTENT (prompt=$PROMPT_TOKENS completion=$COMPLETION_TOKENS cost=\$$CALL_COST)" >>"$LOG"
    update_usage_stats "$NAME" "$MODEL" "$PROMPT_TOKENS" "$COMPLETION_TOKENS" "$TOTAL_TOKENS" "$INPUT_COST" "$OUTPUT_COST"

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
