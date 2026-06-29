# claude-settings

Portable [Claude Code](https://claude.com/claude-code) configuration to reuse across machines.

## `statusline-command.sh`

A custom status line that renders up to five lines. Here's an annotated mock-up:

```
( Opus 4.8 ) high  Sonnet 4.6  Haiku 4.5  │  🐍 3.11.5  ⬡ 18.17.0   ← line 1: model picker + effort | languages
~/Code/Home/claude-settings  │  ⎇ main *3 +2 ↑1                      ← line 2: working dir | git status
██████░░░░  58%   580k/1M                                            ← line 3: context window usage
██░░░░░░░░  23%   session · ↻ 3h08m (2:30am)                         ← line 4: session (5h) limit + reset
█████░░░░░  50%   week    · ↻ 4d20h (Jul 3 8:00pm)                   ← line 5: weekly (7d) limit + reset
```

Claude Code pipes a JSON payload to the script on stdin on every render; each field below names where the value comes from.

### Line 1 — model picker + effort level | languages

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Model picker | `( Opus 4.8 ) Sonnet 4.6 Haiku 4.5` | Switchable models | The `MODELS` list is shown in full; the **active** model (matched against `.model.display_name`, prefix/suffix stripped) gets a purple rounded "pill" with white text, the rest are muted purple. The rounded caps (``/``) need a Nerd Font. |
| Effort | `high` (pink) | Thinking mode | `low`/`medium`/`high` from `.effort.level` when `.thinking.enabled` is true, else `off`. Rendered right beside the active model pill. |
| Languages | `🐍 3.11.5  ⬡ 18.17.0` (green) | Project languages | The script scans the working dir for marker files / source extensions (e.g. `Cargo.toml`, `*.go`, `package.json`, `*.py`) and, for each language found, runs its toolchain (`python3 --version`, `node --version`, `rustc --version`, `go version`, …) and extracts the version with a `[0-9]+\.[0-9]+…` regex. ~20 languages supported; shows up to 4. If the toolchain isn't installed, just the icon is shown. |

#### Language coverage

The language identifier recognizes the following (a language appears only when one of its markers is present in the working dir; the version is shown when its toolchain is installed, otherwise just the icon):

| Lang | Icon | Detected by (marker files / extensions) | Version command |
|---|---|---|---|
| Python | 🐍 | `*.py`, `pyproject.toml`, `requirements.txt`, `setup.py`, `Pipfile`, `.python-version` | `python3 --version` |
| JS / TS / Node | ⬡ | `package.json`, `.nvmrc`, `*.js`, `*.mjs`, `*.cjs`, `*.ts`, `*.tsx`, `tsconfig.json` | `node --version` |
| Rust | 🦀 | `Cargo.toml`, `*.rs` | `rustc --version` |
| Go | 🐹 | `go.mod`, `*.go` | `go version` |
| Ruby | 💎 | `Gemfile`, `*.rb`, `.ruby-version` | `ruby --version` |
| Java | ☕ | `pom.xml`, `build.gradle`, `build.gradle.kts`, `*.java` | `java -version` |
| Kotlin | 🟣 | `*.kt`, `*.kts` | `kotlinc -version` |
| PHP | 🐘 | `composer.json`, `*.php` | `php --version` |
| C# / .NET | 🔷 | `*.csproj`, `*.fsproj`, `*.sln`, `*.cs` | `dotnet --version` |
| Swift | 🕊 | `Package.swift`, `*.swift` | `swift --version` |
| C / C++ | 🔧 | `*.c`, `*.cpp`, `*.cc`, `*.cxx`, `*.h`, `*.hpp`, `CMakeLists.txt` | `cc --version` |
| Elixir | 💧 | `mix.exs`, `*.ex`, `*.exs` | `elixir --version` |
| Haskell | λ | `*.hs`, `stack.yaml`, `*.cabal` | `ghc --version` |
| Scala | 🔺 | `build.sbt`, `*.scala` | `scala -version` |
| Dart | 🎯 | `pubspec.yaml`, `*.dart` | `dart --version` |
| Perl | 🐪 | `*.pl`, `*.pm` | `perl -e 'print $^V'` |
| Zig | ⚡ | `build.zig`, `*.zig` | `zig version` |
| Lua | 🌙 | `*.lua` | `lua -v` |
| R | 📊 | `*.R`, `*.r`, `DESCRIPTION` | `R --version` |
| Julia | ⬢ | `Project.toml`, `*.jl` | `julia --version` |

Add a language by appending one `"icon|version-command|marker globs"` row to the `LANG_DETECTORS` array near the top of the script.

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

### Line 4 — session limit bar (green → yellow → orange → red)

Mirrors the **"Current session"** window in `/usage` — the rolling **5-hour** usage limit.

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Bar + `%` | `██░░░░░░░░ 23%` | Session usage | `.rate_limits.five_hour.used_percentage`, rounded to a 0–10 segment bar. Color escalates: green → yellow (≥50%) → orange (≥80%) → red (≥100%). |
| Detail | `session · ↻ 3h08m (2:30am)` | Time until reset + local reset clock | Countdown and reset time derived from `.rate_limits.five_hour.resets_at` (a Unix epoch). The month/day is prefixed (`Jun 29 2:30am`) only when the reset falls on a later calendar day. |

### Line 5 — weekly limit bar (cyan, darkening to black)

Mirrors the **"Current week"** window in `/usage` — the rolling **7-day** usage limit.

| Element | Example | Represents | How it's retrieved / calculated |
|---|---|---|---|
| Bar + `%` | `█████░░░░░ 50%` | Weekly usage | `.rate_limits.seven_day.used_percentage`, rounded to a 0–10 segment bar. The cyan **darkens as the window fills** — bright cyan (`51`) at 0%, stepping down the 256-color cube's cyan→black diagonal (`51 44 37 30 23 16`) to **black at 100%** ("run out"). The percentage stays bright cyan so the row is legible even when the bar goes dark. |
| Detail | `week · ↻ 4d20h (Jul 3 8:00pm)` | Time until reset + reset date | Countdown and reset time from `.rate_limits.seven_day.resets_at`. The countdown switches to days+hours (`4d20h`) when ≥24h out, and the reset clock is prefixed with the month/day (`Jul 3`). |

Both limit windows come straight from the status-line payload — no external state file is needed; the platform tracks usage. Lines 3–5 share a fixed-width (10-char) bar and right-padded percentage so their detail columns line up, and the `session`/`week` labels are padded so their `·` and reset times align. Line 3 is omitted before the first message (no context data yet).

Tunables: the 256-color constants near the top of the script, and the weekly bar's `cyan_ramp` (the cyan→black shades) in the assembly section near the bottom.

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

Edit the 256-color constants near the top of `~/.claude/statusline-command.sh`, or the weekly bar's `cyan_ramp` (cyan→black fade) further down, to taste. To customize the model picker, edit the `MODELS` list.

**Step 5 — Reload**

Restart Claude Code (or start a new session). The status line appears at the bottom of the prompt.

