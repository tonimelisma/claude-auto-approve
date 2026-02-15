# claude-auto-approve

A Claude Code [hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that automatically approves safe Bash commands using a cheap/free LLM API, so you only get permission prompts for potentially dangerous operations.

## How it works

When Claude Code wants to run a Bash command, this hook intercepts the permission request and asks a cheap LLM whether the command could cause significant damage. Safe commands like `ls`, `git status`, or `cat` are auto-approved. Dangerous commands like `rm -rf`, `mkfs`, or `systemctl stop` trigger the normal permission prompt.

### Provider failover

The script tries multiple API providers in order:

1. **OpenCode** — Kimi K2.5, free (~1.5s latency)
2. **Moonshot** — Kimi K2.5, cheap (~1s latency)

If a provider returns a rate limit error, it enters a 30-minute cooloff period and the next provider is tried.

### Fail-safe design

If all providers fail, time out, or return an unrecognizable response, the hook outputs nothing — which tells Claude Code to show the normal permission prompt. You never accidentally approve a dangerous command due to an API error.

### Classification prompt

The LLM is asked: "Should a system administrator be warned before running this command?" and must answer YES or NO. This framing scored 100% accuracy across 34 test commands covering both safe and dangerous operations.

## Requirements

- `curl`
- `jq`
- API keys from one or more providers (see below)

## Installation

1. Copy the script to your Claude Code hooks directory:

   ```bash
   mkdir -p ~/.claude/hooks
   cp auto-approve-safe.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/auto-approve-safe.sh
   ```

2. Edit the script and replace the placeholder API keys with your own:

   ```bash
   "moonshot|https://api.moonshot.ai/v1/chat/completions|YOUR_MOONSHOT_API_KEY|kimi-k2.5"
   "opencode|https://opencode.ai/zen/v1/chat/completions|YOUR_OPENCODE_API_KEY|kimi-k2.5-free"
   ```

   Get API keys from:
   - **Moonshot**: https://platform.moonshot.ai/ (cheap)
   - **OpenCode**: https://opencode.ai/ (free)

   You can remove providers you don't want or add your own — just follow the `name|url|key|model` format.

3. Add the hook to your Claude Code settings (`~/.claude/settings.json`):

   ```json
   {
     "hooks": {
       "PermissionRequest": [
         {
           "matcher": "Bash",
           "hooks": [
             {
               "type": "command",
               "command": "$HOME/.claude/hooks/auto-approve-safe.sh",
               "timeout": 12
             }
           ]
         }
       ]
     }
   }
   ```

4. Restart Claude Code.

## Adding your own providers

You can add any OpenAI-compatible chat completions API. Add entries to the `PROVIDERS` array in the script:

```bash
"name|https://api.example.com/v1/chat/completions|your-api-key|model-name"
```

The script tries providers in order and uses the first one that succeeds.

## Debugging

All classification decisions are logged to `/tmp/auto-approve-safe.log`:

```
20:01:15 classifying: ls /tmp
  moonshot said: NO
  -> approve
20:01:21 classifying: rm -rf /srv/data
  moonshot said: YES
  -> prompt
```

## Testing

Test a safe command (should output JSON with `"behavior": "allow"`):

```bash
echo '{"tool_input":{"command":"ls /tmp"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

Test a dangerous command (should produce no output):

```bash
echo '{"tool_input":{"command":"rm -rf /"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `COOLOFF_SECONDS` | `1800` | How long to skip a rate-limited provider (seconds) |
| `LOG` | `/tmp/auto-approve-safe.log` | Log file path |
| `--max-time 5` | 5s | curl timeout per provider |
| `timeout` (in settings.json) | 12s | Max time Claude Code waits for the hook |

## License

MIT
