#!/usr/bin/env bash
# Claude Code status line: model picker + context bar + daily budget bar.
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
# (e.g. /Users/you/work/proj -> you/work/proj).
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
dpurple=$'\033[38;5;60m'     # darker/muted purple — unselected models
pillbg=$'\033[48;5;97m'      # darker purple pill background — selected model
pillfg=$'\033[1;38;5;231m'   # white bold — selected model text
pillcap=$'\033[38;5;97m'     # pill end-cap glyph color (matches the background)
cyan=$'\033[38;5;212m'       # pink — thinking mode widget
orange=$'\033[38;5;208m'
horange=$'\033[1;38;5;208m'  # bright bold orange — highlights the context number
dorange=$'\033[38;5;166m'    # darker orange — context bar (distinct from the $ usage bar)
yellow=$'\033[38;5;220m'
red=$'\033[38;5;196m'
dkgreen=$'\033[38;5;28m'
green=$'\033[38;5;40m'       # green — untracked file count
hgreen=$'\033[1;38;5;46m'   # bright bold green — highlights the usage number

# Git segment: branch + modified/untracked counts + ahead/behind (empty outside a repo).
git_seg=""
if branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null \
            || git -C "$dir" rev-parse --short HEAD 2>/dev/null); then
  # Count modified (tracked changes, staged or not) vs untracked (?? entries).
  modified=0; untracked=0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case "$_line" in
      '??'*) untracked=$((untracked + 1)) ;;
      *)     modified=$((modified + 1)) ;;
    esac
  done < <(git -C "$dir" status --porcelain 2>/dev/null)
  marks=""
  [ "$modified"  -gt 0 ] && marks="${marks} ${yellow}*${modified}${reset}"
  [ "$untracked" -gt 0 ] && marks="${marks} ${green}+${untracked}${reset}"
  ab=""
  if counts=$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↑${ahead}"
    [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab="${ab}↓${behind}"
  fi
  [ -n "$ab" ] && ab=" ${gray}${ab}${reset}"
  git_seg="${lblue}⎇ ${branch}${reset}${marks}${ab}"
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

# Usage (daily budget) bar — always present.
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

# Environment segment: detect the project's language(s) from marker files /
# source extensions in the working dir, then show each toolchain's version.
# Each detector is "icon|version-command|space-separated marker globs". A
# language is shown only when one of its markers is present in $dir; the version
# is appended when its toolchain is installed (else just the icon is shown).
env_seg=""
LANG_DETECTORS=(
  "🐍|python3 --version|*.py pyproject.toml requirements.txt setup.py Pipfile .python-version"
  "⬡|node --version|package.json .nvmrc *.js *.mjs *.cjs *.ts *.tsx tsconfig.json"
  "🦀|rustc --version|Cargo.toml *.rs"
  "🐹|go version|go.mod *.go"
  "💎|ruby --version|Gemfile *.rb .ruby-version"
  "☕|java -version|pom.xml build.gradle build.gradle.kts *.java"
  "🟣|kotlinc -version|*.kt *.kts"
  "🐘|php --version|composer.json *.php"
  "🔷|dotnet --version|*.csproj *.fsproj *.sln *.cs"
  "🕊|swift --version|Package.swift *.swift"
  "🔧|cc --version|*.c *.cpp *.cc *.cxx *.h *.hpp CMakeLists.txt"
  "💧|elixir --version|mix.exs *.ex *.exs"
  "λ|ghc --version|*.hs stack.yaml *.cabal"
  "🔺|scala -version|build.sbt *.scala"
  "🎯|dart --version|pubspec.yaml *.dart"
  "🐪|perl -e 'print \"\$^V\"'|*.pl *.pm"
  "⚡|zig version|build.zig *.zig"
  "🌙|lua -v|*.lua"
  "📊|R --version|*.R *.r DESCRIPTION"
  "⬢|julia --version|Project.toml *.jl"
)
lang_count=0
for _entry in "${LANG_DETECTORS[@]}"; do
  IFS='|' read -r _icon _vcmd _markers <<< "$_entry"
  _found=0
  for _pat in $_markers; do
    compgen -G "$dir/$_pat" >/dev/null 2>&1 && { _found=1; break; }
  done
  [ "$_found" -eq 1 ] || continue
  _ver=""
  _bin="${_vcmd%% *}"
  if command -v "$_bin" >/dev/null 2>&1; then
    _ver=$(eval "$_vcmd" 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  fi
  env_seg="${env_seg:+$env_seg  }${green}${_icon}${_ver:+ $_ver}${reset}"
  lang_count=$((lang_count + 1))
  [ "$lang_count" -ge 4 ] && break
done

sep="${dim}│${reset}"

# Model picker: show every switchable model. The active one (matched against the
# current model name) gets a purple rounded "pill" with white text; the rest are
# a muted purple. Edit MODELS to change the list. The rounded caps need a Nerd
# Font; without one they show as boxes (swap pill_l/pill_r for "(" / ")").
MODELS=("Opus 4.8" "Sonnet 4.6" "Haiku 4.5")
pill_l=$''   #  left half-circle
pill_r=$''   #  right half-circle
models_seg=""
matched=0
for _m in "${MODELS[@]}"; do
  if [ "$_m" = "$label" ]; then
    # Active model: pill + effort level right beside it.
    chip="${pillcap}${pill_l}${reset}${pillbg}${pillfg}${_m}${reset}${pillcap}${pill_r}${reset} ${cyan}${think_mode}${reset}"
    matched=1
  else
    chip="${dpurple}${_m}${reset}"
  fi
  models_seg="${models_seg:+$models_seg }${chip}"
done
# If the active model isn't in the list, prepend it as a pill so it still shows.
if [ "$matched" = "0" ] && [ -n "$label" ]; then
  chip="${pillcap}${pill_l}${reset}${pillbg}${pillfg}${label}${reset}${pillcap}${pill_r}${reset} ${cyan}${think_mode}${reset}"
  models_seg="${chip} ${models_seg}"
fi

# Line 1: model picker (active pill carries the effort level) | language versions.
info_line="${models_seg}"
[ -n "$env_seg" ] && info_line="${info_line}  ${sep}  ${env_seg}"

# Line 2: working directory | git status.
top_line="${gray}${short_dir:-~}${reset}"
[ -n "$git_seg" ] && top_line="${top_line}  ${sep}  ${git_seg}"

# Build the context-window row only when context data is available.
ctx_row=""
if [ -n "$used" ]; then
  cpct=$(printf '%.0f' "$used")
  cfill=$(fill_count "$used")
  build_bar "$cfill" "$(( 10 - cfill ))"
  ctx_bar="${dorange}${filled_bar}${reset}${dim}${empty_bar}${reset}"

  # Actual token amount in use vs the context window size, e.g. "53k/1M".
  ctx_used=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)')
  ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
  ctx_detail="$(fmt_tokens "$ctx_used")/$(fmt_tokens "$ctx_size")"
  ctx_row=$(fmt_row "$ctx_bar" "$dorange" "$cpct" "$ctx_detail")
fi

# Assemble: header lines, optional context row, daily budget row.
out="${info_line}"$'\n'"${top_line}"
[ -n "$ctx_row" ] && out="${out}"$'\n'"${ctx_row}"
out="${out}"$'\n'"${usage_row}"
printf '%s' "$out"
