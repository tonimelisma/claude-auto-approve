# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Claude Code hook (`auto-approve-safe.sh`) that intercepts permission requests for Bash commands and WebFetch URLs, classifying them as safe/dangerous using cheap LLM APIs. Safe operations are auto-approved; dangerous ones trigger the normal permission prompt.

Single Bash script. Requires `curl` and `jq`. No build system or package manager.

## Testing

Test safe Bash command (should output JSON with `"behavior": "allow"`):
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}' | ./auto-approve-safe.sh
```

Test dangerous Bash command (should produce no output):
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | ./auto-approve-safe.sh
```

Test safe WebFetch URL (should output JSON with `"behavior": "allow"`):
```bash
echo '{"tool_name":"WebFetch","tool_input":{"url":"https://docs.python.org/3/library/json.html","prompt":"extract info"}}' | ./auto-approve-safe.sh
```

Test dangerous WebFetch URL (should produce no output):
```bash
echo '{"tool_name":"WebFetch","tool_input":{"url":"http://192.168.1.1/admin","prompt":"extract info"}}' | ./auto-approve-safe.sh
```

Note: Omitting `tool_name` defaults to `"Bash"` for backward compatibility.

## Architecture

**Input:** JSON on stdin from Claude Code's `PermissionRequest` hook. Includes `tool_name` (`"Bash"` or `"WebFetch"`) and `tool_input` (`.command` for Bash, `.url` for WebFetch). Missing `tool_name` defaults to `"Bash"` for backward compatibility.

**Output:** JSON with `behavior: "allow"` to auto-approve, or no output to trigger normal permission prompt.

**Flow:** `classify()` reads `tool_name` -> extracts the relevant input (command or URL) -> builds a tool-specific classification prompt -> tries LLM providers in order -> first successful YES/NO response wins -> "NO" (not dangerous) = approve, "YES" (dangerous) = prompt. Unknown tool names fail-safe to prompt.

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

**MANDATORY: Complete ALL steps after EVERY code change. Do NOT stop to ask for confirmation -- just do them all.**

1. Copy API keys from the installed version (`~/.claude/hooks/auto-approve-safe.sh`) into the dev copy
2. Test the dev copy works (safe command -> approve, dangerous command -> no output)
3. Strip API keys back to placeholders in the dev copy (for safe git commit)
4. Install the dev copy to `~/.claude/hooks/auto-approve-safe.sh` with real keys substituted (e.g. via `sed`)
5. Commit and `git push`

**Never** copy on top of the installed version before testing -- that would overwrite the real API keys.
