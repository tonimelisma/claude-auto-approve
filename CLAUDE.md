# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Claude Code hook (`auto-approve-safe.sh`) that intercepts Bash permission requests and classifies commands as safe/dangerous using cheap LLM APIs. Safe commands are auto-approved; dangerous ones trigger the normal permission prompt.

Single Bash script. Requires `curl` and `jq`. No build system or package manager.

## Testing

Test safe command (should output JSON with `"behavior": "allow"`):
```bash
echo '{"tool_input":{"command":"ls /tmp"}}' | ./auto-approve-safe.sh
```

Test dangerous command (should produce no output):
```bash
echo '{"tool_input":{"command":"rm -rf /"}}' | ./auto-approve-safe.sh
```

## Architecture

**Input:** JSON on stdin from Claude Code's `PermissionRequest` hook (`{"tool_input":{"command":"..."}}`).

**Output:** JSON with `behavior: "allow"` to auto-approve, or no output to trigger normal permission prompt.

**Flow:** `classify()` extracts the command -> builds a classification prompt -> tries LLM providers in order -> first successful YES/NO response wins -> "NO" (not dangerous) = approve, "YES" (dangerous) = prompt.

**Fail-safe:** Any failure (API error, timeout, unrecognizable response, all providers down) produces no output, which defaults to showing the permission prompt. The script never accidentally approves. This is the most important invariant -- preserve it.

**Provider system:** Providers are defined as `name|url|key|model|input_cost|output_cost` strings in the `PROVIDERS` array (costs in USD per million tokens). Rate-limited providers enter a 30-minute cooloff tracked via timestamp files in `~/.claude/auto-approve/cooloff/`. `call_api()` wraps curl calls to any OpenAI-compatible chat completions endpoint.

**Usage tracking:** Each successful classification logs a line to `~/.claude/auto-approve/usage.log` with provider, model, token counts, decision, and command. Per-provider cumulative stats (calls, tokens, cost) are maintained in `~/.claude/auto-approve/totals/<provider>` (shell-sourceable). All usage tracking is wrapped in a subshell with `|| true` to preserve the fail-safe invariant.

**State directory:** All persistent state lives under `~/.claude/auto-approve/`:
- `usage.log` -- per-call audit trail (append-only)
- `totals/<provider>` -- per-provider cumulative stats (shell-sourceable key=value)
- `cooloff/<provider>` -- rate-limit cooloff timestamps

## Key Design Decisions

- `set -uo pipefail` but no `-e` -- failures are handled per-provider, not via early exit
- curl timeout is 5s per provider; Claude Code hook timeout should be 12s to allow trying multiple providers

## Deployment Workflow

After any code change, always:
1. Copy API keys from the installed version (`~/.claude/hooks/auto-approve-safe.sh`) into the dev copy
2. Test the dev copy works (safe command -> approve, dangerous command -> no output)
3. Install the dev copy to `~/.claude/hooks/auto-approve-safe.sh` (overwriting it)
4. `git push`

**Never** copy on top of the installed version before testing -- that would overwrite the real API keys.
