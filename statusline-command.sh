#!/usr/bin/env bash
# Claude Code status line: model picker + context bar + session (5h) & weekly (7d) limit bars
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

# --- Rate-limit windows ----------------------------------------------------
# Mirror the /usage view. Claude Code reports two rolling usage windows in the
# payload: rate_limits.five_hour ("Current session") and rate_limits.seven_day
# ("Current week"). Each carries a used_percentage (0-100) and resets_at (a Unix
# epoch); no external state needed — the platform tracks it. Each drives its own
# bar plus a detail showing the label, time-until-reset, and local reset clock,
# e.g. "session · ↻ 4h46m (2:30am)" and "week · ↻ 5d3h (Jul 3 2:30am)".

# fmt_reset <epoch>: set globals reset_in (countdown) and reset_clock (local
# time, prefixed with "Mon D" when the reset isn't today). Countdown shows days
# when >=24h out ("5d3h"), else hours+minutes ("4h46m"). Both empty if epoch<=0.
fmt_reset() {
  reset_in=""; reset_clock=""
  [ "${1:-0}" -gt 0 ] 2>/dev/null || return
  local epoch="$1" secs rday tday mday
  secs=$(( epoch - $(date +%s) ))
  [ "$secs" -lt 0 ] && secs=0
  if [ "$secs" -ge 86400 ]; then
    reset_in=$(printf '%dd%dh' $(( secs / 86400 )) $(( (secs % 86400) / 3600 )))
  else
    reset_in=$(printf '%dh%02dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 )))
  fi
  # Local clock (BSD `date -r`, GNU `date -d @` fallback), lowercased am/pm.
  reset_clock=$(date -r "$epoch" '+%-I:%M%p' 2>/dev/null \
               || date -d "@$epoch" '+%-I:%M%p' 2>/dev/null)
  reset_clock=$(printf '%s' "$reset_clock" | tr 'APM' 'apm')
  # Prefix the month/day when the reset falls on a later calendar day.
  rday=$(date -r "$epoch" '+%Y%m%d' 2>/dev/null || date -d "@$epoch" '+%Y%m%d' 2>/dev/null)
  tday=$(date '+%Y%m%d')
  if [ -n "$rday" ] && [ "$rday" != "$tday" ]; then
    mday=$(date -r "$epoch" '+%b %-d' 2>/dev/null || date -d "@$epoch" '+%b %-d' 2>/dev/null)
    reset_clock="${mday} ${reset_clock}"
  fi
}

# Session (5-hour) window — drives line 4. Labels padded to 8 so the "·" and the
# reset detail line up vertically between the session and weekly rows.
rate_used=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0')
fmt_reset "$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')"
usage_detail="$(printf '%-8s' session)· ↻ ${reset_in:-?} (${reset_clock:-?})"

# Weekly (7-day) window — drives line 5.
week_used=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0')
fmt_reset "$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')"
week_detail="$(printf '%-8s' week)· ↻ ${reset_in:-?} (${reset_clock:-?})"

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
dorange=$'\033[38;5;166m'    # darker orange — context bar (distinct from the limit bars)
yellow=$'\033[38;5;220m'
red=$'\033[38;5;196m'
dkgreen=$'\033[38;5;28m'
green=$'\033[38;5;40m'       # green — untracked file count
hgreen=$'\033[1;38;5;46m'   # bright bold green — highlights the session usage number
hcyan=$'\033[1;38;5;51m'    # bright bold cyan — highlights the weekly usage number

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

# Build a usage-limit row: a 10-segment bar (filled in $3, empty dim), the
# highlighted integer percent (number color $4, default bright green), then the
# dim detail. The caller picks the color scheme so each window can differ.
# $1=percentage (0-100)  $2=detail  $3=filled-bar color  $4=number color (optional)
limit_row() {
  local pct fill
  pct=$(printf '%.0f' "${1:-0}")
  fill=$(fill_count "${1:-0}")
  build_bar "$fill" "$(( 10 - fill ))"
  fmt_row "${3}${filled_bar}${reset}${dim}${empty_bar}${reset}" "${4:-$hgreen}" "$pct" "$2"
}

# --- Assemble the status bar -----------------------------------------------
# Model on its own line, then one aligned row per bar. Both bars start at
# column 0 (no leading whitespace) so alignment survives however the status
# line UI handles indentation.

# Limit rows — session (5h) and weekly (7d) windows, both always present.

# Session bar: severity color — green -> yellow (>=50) -> orange (>=80) -> red (>=100).
srate=$(printf '%.0f' "${rate_used:-0}")
sev_col="$dkgreen"
if   [ "$srate" -ge 100 ]; then sev_col="$red"
elif [ "$srate" -ge 80 ];  then sev_col="$orange"
elif [ "$srate" -ge 50 ];  then sev_col="$yellow"
fi
usage_row=$(limit_row "$rate_used" "$usage_detail" "$sev_col")

# Weekly bar: cyan that darkens toward black as the window fills — bright cyan at
# 0%, black at 100% ("run out"). Shades are the 256-color cube's cyan->black
# diagonal (g=b stepping 5..0 -> 51 44 37 30 23 16); deeper usage picks a darker
# one. The percent stays bright cyan so the row stays legible when the bar darkens.
wrate=$(printf '%.0f' "${week_used:-0}")
cyan_ramp=(51 44 37 30 23 16)
widx=$(( wrate * 5 / 100 )); [ "$widx" -gt 5 ] && widx=5; [ "$widx" -lt 0 ] && widx=0
week_col=$'\033[38;5;'"${cyan_ramp[$widx]}m"
week_row=$(limit_row "$week_used" "$week_detail" "$week_col" "$hcyan")

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

# Assemble: header lines, optional context row, then session + weekly limit rows.
out="${info_line}"$'\n'"${top_line}"
[ -n "$ctx_row" ] && out="${out}"$'\n'"${ctx_row}"
out="${out}"$'\n'"${usage_row}"$'\n'"${week_row}"
printf '%s' "$out"
