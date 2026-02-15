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

Debug log: `/tmp/auto-approve-safe.log`

## Architecture

**Input:** JSON on stdin from Claude Code's `PermissionRequest` hook (`{"tool_input":{"command":"..."}}`).

**Output:** JSON with `behavior: "allow"` to auto-approve, or no output to trigger normal permission prompt.

**Flow:** `classify()` extracts the command → builds a classification prompt → tries LLM providers in order → first successful YES/NO response wins → "NO" (not dangerous) = approve, "YES" (dangerous) = prompt.

**Fail-safe:** Any failure (API error, timeout, unrecognizable response, all providers down) produces no output, which defaults to showing the permission prompt. The script never accidentally approves. This is the most important invariant — preserve it.

**Provider system:** Providers are defined as `name|url|key|model|input_cost|output_cost` strings in the `PROVIDERS` array (costs in USD per million tokens). Rate-limited providers enter a 30-minute cooloff tracked via timestamp files in `/tmp/auto-approve-cooloff/`. `call_api()` wraps curl calls to any OpenAI-compatible chat completions endpoint.

**Usage tracking:** Each successful API call logs token counts and cost to `/tmp/auto-approve-usage.log` (per-call detail) and updates running totals in `/tmp/auto-approve-usage-totals` (shell-sourceable). All usage tracking is wrapped in a subshell with `|| true` to preserve the fail-safe invariant.

## Key Design Decisions

- `set -uo pipefail` but no `-e` — failures are handled per-provider, not via early exit
- curl timeout is 5s per provider; Claude Code hook timeout should be 12s to allow trying multiple providers
