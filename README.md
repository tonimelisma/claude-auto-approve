# claude-auto-approve

A Claude Code [hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that automatically approves safe Bash commands and WebFetch URLs using a cheap/free LLM API, so you only get permission prompts for potentially dangerous operations.

## How it works

When Claude Code wants to run a Bash command or fetch a URL, this hook intercepts the permission request and asks a cheap LLM whether the operation could cause harm. Safe commands like `ls`, `git status`, or `cat` and safe URLs like `https://docs.python.org` are auto-approved. Dangerous commands like `rm -rf` or dangerous URLs like `http://192.168.1.1/admin` trigger the normal permission prompt.

### Provider failover

The script tries multiple API providers in order:

1. **OpenCode** — Kimi K2.5, free (~1.5s latency)
2. **Moonshot** — Kimi K2.5, cheap (~1s latency)

If a provider returns a rate limit error, it enters a 30-minute cooloff period and the next provider is tried.

### Fail-safe design

If all providers fail, time out, or return an unrecognizable response, the hook outputs nothing — which tells Claude Code to show the normal permission prompt. You never accidentally approve a dangerous command due to an API error.

### Classification prompts

For **Bash commands**, the LLM is asked: "Should a system administrator be warned before running this command?" For **WebFetch URLs**, it checks for SSRF risks (private/internal IPs), data exfiltration patterns, and malicious domains. Both must answer YES or NO.

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
   "moonshot|https://api.moonshot.ai/v1/chat/completions|YOUR_MOONSHOT_API_KEY|kimi-k2.5|0.60|3.00"
   "opencode|https://opencode.ai/zen/v1/chat/completions|YOUR_OPENCODE_API_KEY|kimi-k2.5-free|0|0"
   ```

   Get API keys from:
   - **Moonshot**: https://platform.moonshot.ai/ (cheap)
   - **OpenCode**: https://opencode.ai/ (free)

   You can remove providers you don't want or add your own — just follow the `name|url|key|model|input_cost|output_cost` format (costs are USD per million tokens, use `0|0` for free providers).

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
         },
         {
           "matcher": "WebFetch",
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
"name|https://api.example.com/v1/chat/completions|your-api-key|model-name|input_cost|output_cost"
```

Costs are in USD per million tokens. Use `0|0` for free providers.

The script tries providers in order and uses the first one that succeeds.

## Usage tracking

All state lives under `~/.claude/auto-approve/`.

**Per-call audit log:**

```bash
tail -20 ~/.claude/auto-approve/usage.log
```

```
2026-02-14T20:01:15 provider=opencode model=kimi-k2.5-free prompt_tokens=1234 completion_tokens=5 decision=approve command="ls /tmp"
2026-02-14T20:01:18 provider=moonshot model=kimi-k2.5 prompt_tokens=1234 completion_tokens=5 decision=prompt command="rm -rf /"
```

**Per-provider cumulative totals** (shell-sourceable):

```bash
cat ~/.claude/auto-approve/totals/opencode
```

```
CALLS=42
PROMPT_TOKENS=5000
COMPLETION_TOKENS=200
COST_USD=0.00
```

To reset usage stats: `rm -rf ~/.claude/auto-approve/totals/ ~/.claude/auto-approve/usage.log`

## Testing

Test a safe Bash command (should output JSON with `"behavior": "allow"`):

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

Test a dangerous Bash command (should produce no output):

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

Test a safe WebFetch URL (should output JSON with `"behavior": "allow"`):

```bash
echo '{"tool_name":"WebFetch","tool_input":{"url":"https://docs.python.org/3/library/json.html","prompt":"extract info"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

Test a dangerous WebFetch URL (should produce no output):

```bash
echo '{"tool_name":"WebFetch","tool_input":{"url":"http://192.168.1.1/admin","prompt":"extract info"}}' | ~/.claude/hooks/auto-approve-safe.sh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `COOLOFF_SECONDS` | `1800` | How long to skip a rate-limited provider (seconds) |
| `DATA_DIR` | `~/.claude/auto-approve` | State directory for logs, totals, cooloff |
| `--max-time 5` | 5s | curl timeout per provider |
| `timeout` (in settings.json) | 12s | Max time Claude Code waits for the hook |

## License

MIT
