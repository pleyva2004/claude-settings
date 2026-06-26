# claude-settings

Portable [Claude Code](https://claude.com/claude-code) configuration to reuse across machines.

## `statusline-command.sh`

A custom status line that renders up to three lines:

1. **Header** — working directory · model name · thinking mode (pink) · git branch (light blue) with dirty marker and ahead/behind counts.
2. **Context bar** (orange) — percent of the context window used, plus actual tokens used / window size (e.g. `53k/1M`).
3. **Daily budget bar** (green → yellow → orange → red) — spend against a configurable daily budget. Because Claude Code only reports per-session cost, the script persists each session's cost to `~/.claude/daily-usage.json` keyed by date and sums across all of today's sessions.

Tunables at the top of the script: `DAILY_BUDGET` (default `300`) and the 256-color constants.

### Install

```sh
# 1. copy the script into your Claude config dir
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh

# 2. point Claude Code at it in ~/.claude/settings.json
#    "statusLine": {
#      "type": "command",
#      "command": "bash /Users/<you>/.claude/statusline-command.sh"
#    }
```

Requires `jq`, `awk`, and `git` on `PATH`.
