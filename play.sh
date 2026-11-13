#!/bin/bash
# Usage: play.sh <category>
# Plays a random sound for the category from the active pack, in the background.
# Config: config.json (overrides config.default.json). Env FART_VOLUME overrides volume.
# Always exits 0 and prints nothing, so it is safe on every hook event
# (stdout of some events, e.g. SessionStart, is fed to Claude as context).

category="${1:-}"
[ -z "$category" ] && exit 0
root="$(cd "$(dirname "$0")" && pwd)"

# Claude Code passes hook JSON on stdin; we don't need it, but drain it.
cat >/dev/null 2>&1 || true
command -v jq >/dev/null 2>&1 || exit 0

# ---- config (defaults merged with user config; broken user config -> defaults)
user_cfg="$root/config.json"; [ -f "$user_cfg" ] || user_cfg=/dev/null
C=$(jq -s '.[0] * (.[1] // {})' "$root/config.default.json" "$user_cfg" 2>/dev/null) \
  || C=$(cat "$root/config.default.json" 2>/dev/null)
[ -n "$C" ] || exit 0
cfg() { jq -r "$1" <<<"$C" 2>/dev/null; }

[ "$(cfg '.enabled')" = "false" ] && exit 0
case "$category" in */*|.*) category=misc ;; esac

state="$root/.state"; mkdir -p "$state" 2>/dev/null

# ---- "annoyed": too many prompts in a short window -> category spam
if [ "$category" = prompt ]; then
  thr=$(cfg '.annoyed_threshold'); win=$(cfg '.annoyed_window_seconds')
  case "$thr" in ''|*[!0-9]*) thr=3 ;; esac
  case "$win" in ''|*[!0-9]*) win=10 ;; esac
  if [ "$thr" -gt 0 ]; then
    now=$(date +%s)
    recent=$( { [ -f "$state/prompts" ] && cat "$state/prompts"; echo "$now"; } \
      | awk -v n="$now" -v w="$win" '$1 ~ /^[0-9]+$/ && n - $1 <= w' )
    printf '%s\n' "$recent" > "$state/prompts" 2>/dev/null
    [ "$(printf '%s\n' "$recent" | grep -c .)" -ge "$thr" ] && category=spam
  fi
fi

# ---- per-category switch
# note: `// true` would turn an explicit false into true in jq, so compare instead
[ "$(jq -r --arg c "$category" 'if .categories[$c] == false then "off" else "on" end' <<<"$C")" = "off" ] && exit 0

# ---- notifications (desktop / push), only if configured; fixed texts, no session data
notify() {
  local msg
  case "$category" in
    stop) msg="Claude finished" ;;
    notification) msg="Claude is waiting for you" ;;
    permission) msg="Claude needs your permission" ;;
    error) msg="Something failed" ;;
    *) return ;;
  esac
  jq -e --arg c "$category" '.notifications.categories // [] | index($c)' <<<"$C" >/dev/null 2>&1 || return
  if [ "$(cfg '.notifications.desktop')" = "true" ]; then
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"$msg\" with title \"claude-fart-ping\""
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "claude-fart-ping" "$msg"
    fi
  fi
  command -v curl >/dev/null 2>&1 || return
  local topic server token chat user
  topic=$(cfg '.notifications.ntfy.topic'); server=$(cfg '.notifications.ntfy.server')
  if [ -n "$topic" ]; then
    curl -fsS -m 5 -H "Title: claude-fart-ping" -d "$msg" "${server%/}/$topic"
  fi
  token=$(cfg '.notifications.telegram.token'); chat=$(cfg '.notifications.telegram.chat_id')
  if [ -n "$token" ] && [ -n "$chat" ]; then   # secrets via stdin config, not argv
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' "$token" "$chat" "$msg" \
      | curl -fsS -m 5 -K -
  fi
  user=$(cfg '.notifications.pushover.user'); token=$(cfg '.notifications.pushover.token')
  if [ -n "$user" ] && [ -n "$token" ]; then
    printf 'url = "https://api.pushover.net/1/messages.json"\ndata-urlencode = "token=%s"\ndata-urlencode = "user=%s"\ndata-urlencode = "message=%s"\n' "$token" "$user" "$msg" \
      | curl -fsS -m 5 -K -
  fi
}
( notify >/dev/null 2>&1 & )

# ---- pick pack (rotation -> random one of the list)
rot=$(jq -r '.pack_rotation // [] | .[]' <<<"$C" 2>/dev/null | grep -v '^$')
if [ -n "$rot" ]; then pack=$(printf '%s\n' "$rot" | sort -R | head -1); else pack=$(cfg '.active_pack'); fi
case "$pack" in ''|*/*|.*|null) pack=default ;; esac
[ -d "$root/packs/$pack" ] || pack=default
pdir="$root/packs/$pack"
[ -d "$pdir" ] || exit 0

# ---- pick sound: category folder (spam falls back to stop), else any sound in the pack
files() {
  find "$1" -maxdepth "$2" -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aiff' \) 2>/dev/null
}
case "$category" in spam) chain="spam stop" ;; *) chain="$category" ;; esac
cands=""
for c in $chain; do
  [ -d "$pdir/$c" ] && cands=$(files "$pdir/$c" 1)
  [ -n "$cands" ] && break
done
[ -n "$cands" ] || cands=$(files "$pdir" 2)
[ -n "$cands" ] || exit 0

# anti-repeat: never the same clip twice in a row for a category (if there is a choice)
last=$(cat "$state/last-$category" 2>/dev/null)
if [ -n "$last" ] && [ "$(printf '%s\n' "$cands" | grep -c .)" -gt 1 ]; then
  cands=$(printf '%s\n' "$cands" | grep -vxF -- "$last")
fi
file=$(printf '%s\n' "$cands" | sort -R | head -1)
printf '%s\n' "$file" > "$state/last-$category" 2>/dev/null

vol="${FART_VOLUME:-$(cfg '.volume')}"
[[ "$vol" =~ ^(0|1|0?\.[0-9]+|1\.0+)$ ]] || vol=0.7

play() {
  if command -v afplay >/dev/null 2>&1; then
    afplay -v "$vol" "$file"
  elif command -v mpv >/dev/null 2>&1; then
    mpv --no-video --really-quiet --volume="$(awk -v v="$vol" 'BEGIN{printf "%d", v*100}')" "$file"
  elif command -v ffplay >/dev/null 2>&1; then
    ffplay -nodisp -autoexit -loglevel quiet -volume "$(awk -v v="$vol" 'BEGIN{printf "%d", v*100}')" "$file"
  elif command -v mpg123 >/dev/null 2>&1; then
    mpg123 -q "$file"
  elif command -v paplay >/dev/null 2>&1; then
    paplay "$file"
  fi
}
( play >/dev/null 2>&1 & )
exit 0
