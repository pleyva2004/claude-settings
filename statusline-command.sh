#!/usr/bin/env bash
# Claude Code status line: model name + context bar (orange) + usage bar (dark green)
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
# Strip leading "Claude " prefix for brevity (e.g. "Claude Opus 4" -> "Opus 4")
model="${model#Claude }"
# Drop any trailing parenthetical (e.g. "Opus 4.8 (1M context)" -> "Opus 4.8")
model="${model% (*)}"

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Thinking mode: show the reasoning effort level when thinking is enabled,
# otherwise "off". e.g. enabled + effort.level "high" -> "high".
thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // false')
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
if [ "$thinking_enabled" = "true" ]; then
  think_mode="${effort_level:-on}"
else
  think_mode="off"
fi

# Fall back to computing from remaining_percentage if used_percentage absent
if [ -z "$used" ]; then
  remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
  if [ -n "$remaining" ]; then
    used=$(awk "BEGIN { printf \"%.6f\", 100 - $remaining }")
  fi
fi

# --- Daily budget tracking -------------------------------------------------
# The status-line payload only reports cost.total_cost_usd for the CURRENT
# session, and it resets to 0 each new session. To track a DAILY total across
# every session, persist each session's cumulative cost to a state file keyed
# by date, then sum across sessions on each render.
DAILY_BUDGET=300
state="$HOME/.claude/daily-usage.json"
today=$(date +%Y-%m-%d)

session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Reset state at the start of a new day (or if the file is missing/corrupt).
if [ ! -f "$state" ] || [ "$(jq -r '.date // empty' "$state" 2>/dev/null)" != "$today" ]; then
  printf '{"date":"%s","sessions":{}}' "$today" > "$state"
fi

# Record this session's cumulative cost (max guards against a transient 0
# overwriting a real value), then sum all of today's sessions. Write via a
# temp file + atomic mv so concurrent renders can't corrupt the state.
tmp=$(mktemp)
if jq --arg sid "$session_id" --argjson c "$session_cost" \
     '.sessions[$sid] = ([.sessions[$sid] // 0, $c] | max)' \
     "$state" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$state"
else
  rm -f "$tmp"
fi

daily_total=$(jq -r '[.sessions[]] | add // 0' "$state" 2>/dev/null)
[ -z "$daily_total" ] && daily_total=0

# Percentage of the daily budget consumed (drives the usage bar), capped at 100.
rate_used=$(awk "BEGIN { p = $daily_total / $DAILY_BUDGET * 100; if (p > 100) p = 100; printf \"%.2f\", p }")
# Dollar detail shown next to the bar, e.g. "\$6.50/\$300".
usage_detail=$(awk "BEGIN { printf \"\$%.0f/\$%d\", $daily_total, $DAILY_BUDGET }")

label="${model:-Claude}"

# Current working directory, shortened to its last 3 path components
# (e.g. /Users/pabloleyva/work/proj -> pabloleyva/work/proj).
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
dir="${dir%/}"
IFS='/' read -ra _parts <<< "$dir"
short_dir=""
_n=${#_parts[@]}
_start=$(( _n > 3 ? _n - 3 : 0 ))
for (( _i = _start; _i < _n; _i++ )); do
  [ -n "${_parts[_i]}" ] && short_dir="${short_dir:+$short_dir/}${_parts[_i]}"
done

# Color constants (real ESC bytes so they can be concatenated into strings)
reset=$'\033[0m'
dim=$'\033[2m'
gray=$'\033[38;5;245m'      # muted gray — directory path
lblue=$'\033[38;5;117m'     # light blue — git branch name
purple=$'\033[38;5;141m'
cyan=$'\033[38;5;212m'       # pink — thinking mode widget
orange=$'\033[38;5;208m'
horange=$'\033[1;38;5;208m'  # bright bold orange — highlights the context number
yellow=$'\033[38;5;220m'
red=$'\033[38;5;196m'
dkgreen=$'\033[38;5;28m'
hgreen=$'\033[1;38;5;46m'   # bright bold green — highlights the usage number

# Git segment: branch + dirty marker + ahead/behind (empty outside a repo).
git_seg=""
if branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null \
            || git -C "$dir" rev-parse --short HEAD 2>/dev/null); then
  dirty=""
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && dirty="*"
  ab=""
  if counts=$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↑${ahead}"
    [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↓${behind}"
  fi
  git_seg="${lblue}⎇ ${branch}${reset}${yellow}${dirty}${reset}${gray}${ab}${reset}"
fi

# Helper: build a 10-segment filled/empty bar string given a filled count
# Usage: build_bar <filled_count> <empty_count>
# Results are stored in global filled_bar / empty_bar
build_bar() {
  local f="$1" e="$2"
  filled_bar=""
  empty_bar=""
  local i
  for (( i = 0; i < f; i++ )); do filled_bar="${filled_bar}█"; done
  for (( i = 0; i < e; i++ )); do empty_bar="${empty_bar}░"; done
}

# Helper: format a raw token count compactly (e.g. 52609 -> 53k, 1000000 -> 1M)
fmt_tokens() {
  awk "BEGIN {
    n = $1
    if (n >= 1000000)      { v = n/1000000; if (v == int(v)) printf \"%dM\", v; else printf \"%.1fM\", v }
    else if (n >= 1000)    { printf \"%.0fk\", n/1000 }
    else                   { printf \"%d\", n }
  }"
}

# Round a percentage to a 0–10 segment count (proportional, nearest segment).
fill_count() { awk "BEGIN { f = int($1/10 + 0.5); if (f>10) f=10; if (f<0) f=0; print f }"; }

# Format one metric row: <10-wide colored bar> <highlighted NN%> <dim detail>.
# Rows align across lines because the bar is fixed-width (10) and the percentage
# is right-padded to 4 chars, so every dim detail starts at the same column.
# $1=colored bar  $2=number color  $3=integer percent  $4=dim detail
fmt_row() { printf '%s %s%3d%%%s   %s%s%s' "$1" "$2" "$3" "$reset" "$dim" "$4" "$reset"; }

# --- Assemble the status bar -----------------------------------------------
# Model on its own line, then one aligned row per bar. Both bars start at
# column 0 (no leading whitespace) so alignment survives however the status
# line UI handles indentation.

# Usage (budget) bar — always present.
urate=$(printf '%.0f' "${rate_used:-0}")
ufill=$(fill_count "${rate_used:-0}")
build_bar "$ufill" "$(( 10 - ufill ))"
ubarcol="$dkgreen"
if   [ "$urate" -ge 100 ]; then ubarcol="$red"
elif [ "$urate" -ge 80 ];  then ubarcol="$orange"
elif [ "$urate" -ge 50 ];  then ubarcol="$yellow"
fi
usage_bar="${ubarcol}${filled_bar}${reset}${dim}${empty_bar}${reset}"
usage_row=$(fmt_row "$usage_bar" "$hgreen" "$urate" "$usage_detail")

# Header line: path · model · thinking mode, then git segment.
header="${purple}${label}${reset} ${cyan}${think_mode}${reset}"
[ -n "$short_dir" ] && header="${gray}${short_dir}${reset} ${gray}·${reset} ${header}"
[ -n "$git_seg" ]   && header="${header}  ${git_seg}"

if [ -z "$used" ]; then
  # No context data yet (before first message): header + usage row.
  printf '%s\n%s' "$header" "$usage_row"
else
  cpct=$(printf '%.0f' "$used")
  cfill=$(fill_count "$used")
  build_bar "$cfill" "$(( 10 - cfill ))"
  ctx_bar="${orange}${filled_bar}${reset}${dim}${empty_bar}${reset}"

  # Actual token amount in use vs the context window size, e.g. "53k/1M".
  ctx_used=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)')
  ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
  ctx_detail="$(fmt_tokens "$ctx_used")/$(fmt_tokens "$ctx_size")"
  ctx_row=$(fmt_row "$ctx_bar" "$horange" "$cpct" "$ctx_detail")

  printf '%s\n%s\n%s' "$header" "$ctx_row" "$usage_row"
fi
