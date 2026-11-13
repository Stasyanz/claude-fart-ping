#!/bin/bash
# Usage: play.sh <category>   (stop | notification | permission)
# Plays a random sound from sounds/<category>/ in the background.
# Env: FART_VOLUME (0.0-1.0, default 0.7)

category="${1:-}"
[ -z "$category" ] && exit 0

root="$(cd "$(dirname "$0")" && pwd)"
dir="$root/sounds/$category"
volume="${FART_VOLUME:-0.7}"

# Claude Code passes hook JSON on stdin; we don't need it, but drain it.
cat >/dev/null 2>&1 || true

[ -d "$dir" ] || exit 0

file=$(find "$dir" -maxdepth 1 -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aiff' \) | sort -R | head -1)
[ -n "$file" ] || exit 0

play() {
  if command -v afplay >/dev/null 2>&1; then
    afplay -v "$volume" "$file"
  elif command -v mpv >/dev/null 2>&1; then
    mpv --no-video --really-quiet --volume="$(awk -v v="$volume" 'BEGIN{printf "%d", v*100}')" "$file"
  elif command -v ffplay >/dev/null 2>&1; then
    ffplay -nodisp -autoexit -loglevel quiet -volume "$(awk -v v="$volume" 'BEGIN{printf "%d", v*100}')" "$file"
  elif command -v mpg123 >/dev/null 2>&1; then
    mpg123 -q "$file"
  elif command -v paplay >/dev/null 2>&1; then
    paplay "$file"
  fi
}

# Background so the hook never blocks Claude
( play >/dev/null 2>&1 & )
exit 0
