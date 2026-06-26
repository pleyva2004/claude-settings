# claude-settings

Portable [Claude Code](https://claude.com/claude-code) configuration to reuse across machines.

## `statusline-command.sh`

A custom status line that renders up to four lines. Here's an annotated mock-up:

```
Opus 4.8 high  │  🐍 3.11.5  ⬡ 18.17.0  │  22:55      ← line 1: model · effort | languages | clock
~/Code/Home/claude-settings  │  ⎇ main*3+2 ↑1         ← line 2: working dir | git status
██████░░░░  58%   580k/1M                             ← line 3: context window usage
███░░░░░░░  31%   $93/$300                            ← line 4: daily budget usage
```

Claude Code pipes a JSON payload to the script on stdin on every render; each field below names where the value comes from.

### Line 1 — model · effort level | languages | clock

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Model | `Opus 4.8` | Active model | `.model.display_name`, with the `Claude ` prefix and any ` (… )` suffix stripped. |
| Effort | `high` (pink) | Thinking mode | `low`/`medium`/`high` from `.effort.level` when `.thinking.enabled` is true, else `off`. |
| Languages | `🐍 3.11.5  ⬡ 18.17.0` (green) | Project languages | The script scans the working dir for marker files / source extensions (e.g. `Cargo.toml`, `*.go`, `package.json`, `*.py`) and, for each language found, runs its toolchain (`python3 --version`, `node --version`, `rustc --version`, `go version`, …) and extracts the version with a `[0-9]+\.[0-9]+…` regex. ~20 languages supported; shows up to 4. If the toolchain isn't installed, just the icon is shown. |
| Clock | `22:55` | Local time | `date +%H:%M`. |

### Line 2 — working directory | git status

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Directory | `~/Code/Home/claude-settings` | Working dir | `.workspace.current_dir` (falls back to `.cwd`), shortened to its last 3 path components. |
| Branch | `⎇ main` (light blue) | Git branch | `git symbolic-ref --short HEAD` (falls back to a short SHA when detached). Whole segment is empty outside a repo. |
| `*N` | `*3` (yellow) | Modified tracked files | Count of `git status --porcelain` lines **not** starting with `??`. |
| `+N` | `+2` (green) | Untracked files | Count of `git status --porcelain` lines starting with `??`. |
| `↑N` / `↓N` | `↑1` | Ahead / behind upstream | `git rev-list --left-right --count @{u}...HEAD`. |

### Line 3 — context window bar (orange)

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Bar + `%` | `██████░░░░ 58%` | Context window used | `.context_window.used_percentage` (or `100 − remaining_percentage`), rounded to a 0–10 segment bar. |
| Detail | `580k/1M` | Tokens used / window size | `(.total_input_tokens + .total_output_tokens)` over `.context_window_size`, formatted compactly (`580k`, `1M`). |

### Line 4 — daily budget bar (green → yellow → orange → red)

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Bar + `%` | `███░░░░░░░ 31%` | Spend vs daily budget | Daily total ÷ `DAILY_BUDGET` (default `300`). Color escalates: green → yellow (≥50%) → orange (≥80%) → red (≥100%). |
| Detail | `$93/$300` | Today's spend / budget | The payload only reports **per-session** cost (`.cost.total_cost_usd`, which resets each session), so the script persists each session's cost to `~/.claude/daily-usage.json` keyed by date, then **sums all of today's sessions** to get the true daily total. Written atomically (temp file + `mv`) so concurrent renders can't corrupt the state. |

Lines 3 and 4 share a fixed-width (10-char) bar and right-padded percentage so their detail columns line up. Line 3 is omitted before the first message (no context data yet).

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

