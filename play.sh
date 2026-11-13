#!/bin/bash
# Usage: play.sh <category> [event]
# Plays a random sound for the category from the active pack, in the background.
# <event> (hook event name, optional) decides whether a push/desktop notification is sent.
# Config: config.json (overrides config.default.json). Env FART_VOLUME overrides volume.
# Env FART_SYNC=1 runs player and notifier in the foreground (used by tests).
# Always exits 0 and prints nothing, so it is safe on every hook event
# (stdout of some events, e.g. SessionStart, is fed to Claude as context).

category="${1:-}"; event="${2:-}"
[ -z "$category" ] && exit 0
exec 2>/dev/null
root="$(cd "$(dirname "$0")" && pwd)"

# Claude Code passes hook JSON on stdin; we don't need it. Drain it, but never wait on a terminal.
[ -t 0 ] || cat >/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

bg() { if [ -n "${FART_SYNC:-}" ]; then "$@" >/dev/null 2>&1; else ( "$@" >/dev/null 2>&1 & ); fi; }

# ---- config (defaults merged with user config; broken user config -> defaults)
user_cfg="$root/config.json"; [ -f "$user_cfg" ] || user_cfg=/dev/null
C=$(jq -s '.[0] * (.[1] // {})' "$root/config.default.json" "$user_cfg") \
  || C=$(cat "$root/config.default.json")
[ -n "$C" ] || exit 0
cfg() { jq -r "$1" <<<"$C"; }
# num <value> <default> [max_digits=6]: value if it is a plain number with at most max_digits digits, else default
num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) [ "${#1}" -le "${3:-6}" ] && echo "$1" || echo "$2" ;; esac; }

[ "$(cfg '.enabled')" = "false" ] && exit 0
case "$category" in */*|.*) category=misc ;; esac

state="$root/.state"; mkdir -p "$state"

# ---- "annoyed": too many prompts in a short window -> category spam
if [ "$category" = prompt ]; then
  thr=$(num "$(cfg '.annoyed_threshold')" 3); win=$(num "$(cfg '.annoyed_window_seconds')" 10)
  if [ "$thr" -gt 0 ]; then
    now=$(date +%s)
    echo "$now" >> "$state/prompts"     # append is atomic for short lines: no lost updates
    recent=$(awk -v n="$now" -v w="$win" '$1 ~ /^[0-9]+$/ && n - $1 <= w' "$state/prompts")
    count=$(printf '%s\n' "$recent" | grep -c .)
    [ "$count" -gt 50 ] && printf '%s\n' "$recent" > "$state/prompts"   # trim
    [ "$count" -ge "$thr" ] && category=spam
  fi
fi

# ---- per-category switch (note: `// true` would turn an explicit false into true in jq)
[ "$(jq -r --arg c "$category" 'if .categories[$c] == false then "off" else "on" end' <<<"$C")" = "off" ] && exit 0

# ---- notifications (desktop / push). Only for a few events, fixed texts, no session data.
re_topic='^[A-Za-z0-9_-]+$'
re_server='^https?://[A-Za-z0-9._:/-]+$'
re_tgtoken='^[0-9]+:[A-Za-z0-9_-]+$'
re_tgchat='^(-?[0-9]+|@[A-Za-z0-9_]+)$'
re_alnum='^[A-Za-z0-9]+$'

notify() {
  local msg key
  case "$event" in
    Stop)              msg="Claude finished";            key=finished ;;
    Notification)      msg="Claude is waiting for you";  key=input ;;
    PermissionRequest) msg="Claude needs your permission"; key=input ;;
    StopFailure)       msg="Something failed";           key=error ;;
    *) return ;;
  esac
  jq -e --arg c "$category" '.notifications.categories // [] | index($c)' <<<"$C" >/dev/null || return
  # throttle per key (Notification + PermissionRequest fire together; subagents fire Stop too)
  local min now last; min=$(num "$(cfg '.notifications.min_interval_seconds')" 15); now=$(date +%s)
  last=$(cat "$state/notify-$key"); last=$(num "$last" 0 12)
  [ "$last" -gt 0 ] && [ $((now - last)) -lt "$min" ] && return
  echo "$now" > "$state/notify-$key"

  if [ "$(cfg '.notifications.desktop')" = "true" ]; then
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"$msg\" with title \"claude-fart-ping\""
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "claude-fart-ping" "$msg"
    fi
  fi
  command -v curl >/dev/null 2>&1 || return
  # Values come from config.json, which may be hand-edited: validate before they go into a curl config.
  # Secrets travel via stdin (-K -), never argv.
  local topic server token chat user
  topic=$(cfg '.notifications.ntfy.topic'); server=$(cfg '.notifications.ntfy.server'); [ -n "$server" ] || server=https://ntfy.sh
  if [[ "$topic" =~ $re_topic ]] && [[ "$server" =~ $re_server ]]; then
    printf 'url = "%s/%s"\nheader = "Title: claude-fart-ping"\ndata = "%s"\n' "${server%/}" "$topic" "$msg" | curl -fsS -m 5 -K -
  fi
  token=$(cfg '.notifications.telegram.token'); chat=$(cfg '.notifications.telegram.chat_id')
  if [[ "$token" =~ $re_tgtoken ]] && [[ "$chat" =~ $re_tgchat ]]; then
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' "$token" "$chat" "$msg" | curl -fsS -m 5 -K -
  fi
  user=$(cfg '.notifications.pushover.user'); token=$(cfg '.notifications.pushover.token')
  if [[ "$user" =~ $re_alnum ]] && [[ "$token" =~ $re_alnum ]]; then
    printf 'url = "https://api.pushover.net/1/messages.json"\ndata-urlencode = "token=%s"\ndata-urlencode = "user=%s"\ndata-urlencode = "message=%s"\n' "$token" "$user" "$msg" | curl -fsS -m 5 -K -
  fi
}
bg notify

# ---- pick pack (rotation -> random one of the list)
rot=$(jq -r '.pack_rotation // [] | .[]' <<<"$C" | grep -v '^$')
if [ -n "$rot" ]; then pack=$(printf '%s\n' "$rot" | sort -R | head -1); else pack=$(cfg '.active_pack'); fi
case "$pack" in ''|*/*|.*|null) pack=default ;; esac
[ -d "$root/packs/$pack" ] || pack=default
pdir="$root/packs/$pack"
[ -d "$pdir" ] || exit 0

# ---- pick sound: category folder (spam falls back to stop), else any sound in the pack.
# Trailing slash on the start path makes find enter a symlinked pack/category folder.
files() {
  find "$1/" -maxdepth "$2" -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aiff' \) | sed 's#//*#/#g'
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
last=$(cat "$state/last-$category")
if [ -n "$last" ] && [ "$(printf '%s\n' "$cands" | grep -c .)" -gt 1 ]; then
  cands=$(printf '%s\n' "$cands" | grep -vxF -- "$last")
fi
file=$(printf '%s\n' "$cands" | sort -R | head -1)
printf '%s\n' "$file" > "$state/last-$category"

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
bg play
exit 0
