#!/bin/bash
# Usage: play.sh <category>
# Plays a random sound from sounds/<category>/ in the background.
# If that folder has no sounds, falls back to a random sound from any folder.
# Env: FART_VOLUME (0.0-1.0, default 0.7)
# Always exits 0 and prints nothing, so it is safe on every hook event
# (stdout of some events, e.g. SessionStart, is fed to Claude as context).

category="${1:-}"
[ -z "$category" ] && exit 0

root="$(cd "$(dirname "$0")" && pwd)"
volume="${FART_VOLUME:-0.7}"

# Claude Code passes hook JSON on stdin; we don't need it, but drain it.
cat >/dev/null 2>&1 || true

pick() {
  find "$1" -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aiff' \) 2>/dev/null | sort -R | head -1
}

file=""
case "$category" in */*|.*) ;; *) [ -d "$root/sounds/$category" ] && file=$(pick "$root/sounds/$category") ;; esac
[ -n "$file" ] || file=$(pick "$root/sounds")
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
