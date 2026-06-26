# claude-settings

Portable [Claude Code](https://claude.com/claude-code) configuration to reuse across machines.

## `statusline-command.sh`

A custom status line that renders up to three lines:

1. **Header** — working directory · model name · thinking mode (pink) · git branch (light blue) with dirty marker and ahead/behind counts.
2. **Context bar** (orange) — percent of the context window used, plus actual tokens used / window size (e.g. `53k/1M`).
3. **Daily budget bar** (green → yellow → orange → red) — spend against a configurable daily budget. Because Claude Code only reports per-session cost, the script persists each session's cost to `~/.claude/daily-usage.json` keyed by date and sums across all of today's sessions.

Tunables at the top of the script: `DAILY_BUDGET` (default `300`) and the 256-color constants.

### Install

Requires `jq`, `awk`, and `git` on your `PATH`.

**Step 1 — Clone this repo**

```sh
git clone https://github.com/pleyva2004/claude-settings.git
cd claude-settings
```

**Step 2 — Copy the script into your Claude config directory**

```sh
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

**Step 3 — Point Claude Code at the script**

Add this block to `~/.claude/settings.json` (replace `<you>` with your username):

```json
"statusLine": {
  "type": "command",
  "command": "bash /Users/<you>/.claude/statusline-command.sh"
}
```

**Step 4 — (Optional) Tune it**

Edit the top of `~/.claude/statusline-command.sh` to change `DAILY_BUDGET` (default `300`) or the 256-color constants.

**Step 5 — Reload**

Restart Claude Code (or start a new session). The status line appears at the bottom of the prompt.

