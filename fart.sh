#!/bin/bash
# fart — control claude-fart-ping. Run `fart help`.
set -uo pipefail
src="${BASH_SOURCE[0]}"; [ -L "$src" ] && src="$(readlink "$src")"
root="$(cd "$(dirname "$src")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
die() { echo "error: $*" >&2; exit 1; }
resolve() { local p="$1" l; while [ -L "$p" ]; do l="$(readlink "$p")"; case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac; done; echo "$p"; }
cfgfile="$(resolve "$root/config.json")"
# `edit <jq args>`: rewrite config.json atomically (chmod 600, temp file always cleaned up)
edit() {
  local tmp rc; tmp="$(mktemp "$cfgfile.XXXXXX")" || return 1
  jq "$@" "$cfgfile" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$cfgfile"; rc=$?
  rm -f "$tmp"; return $rc
}
merged() { jq -s '.[0] * (.[1] // {})' "$root/config.default.json" "$cfgfile"; }
name_ok() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
pack_exists() { name_ok "$1" && [ -d "$root/packs/$1" ]; }
count_sounds() { find "$1" -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aiff' \) | grep -c .; }

usage() { cat <<'USAGE'
fart <command>
  on | off | toggle          enable / disable all sounds and notifications
  status                     show current settings
  volume <0.0-1.0>           set volume
  packs                      list sound packs
  use <pack>                 switch to a pack (turns rotation off)
  rotate <a,b,c> | off       pick a random pack from the list on every play
  category <name> on|off     mute/unmute one category (stop, error, spam, ...)
  annoyed <count> <seconds>  "annoyed" sound after <count> prompts within <seconds> (count 0 = off)
  notify desktop on|off      system notifications
  notify ntfy <topic> [server]
  notify telegram <bot_token> <chat_id>
  notify pushover <user_key> <app_token>
  notify categories <a,b,c>  which categories notify (default: stop,notification,permission,error)
  notify off                 turn off all notifications
  test [category] [event]    play a sound now (default: stop); with an event, notifications fire too
USAGE
}

cmd="${1:-help}"; shift || true
case "$cmd" in help|-h|--help) usage; exit 0 ;; esac

[ -f "$cfgfile" ] || { echo '{}' > "$cfgfile"; chmod 600 "$cfgfile"; }
jq empty "$cfgfile" 2>/dev/null || die "$cfgfile is not valid JSON"
case "$cmd" in
  on)  edit '.enabled = true'  && echo "claude-fart-ping: on" ;;
  off) edit '.enabled = false' && echo "claude-fart-ping: off (run 'fart on' to resume)" ;;
  toggle)
    if [ "$(merged | jq -r .enabled)" = "false" ]; then edit '.enabled = true'; echo "claude-fart-ping: on"
    else edit '.enabled = false'; echo "claude-fart-ping: off"; fi ;;
  volume)
    [[ "${1:-}" =~ ^(0|1|0?\.[0-9]+|1\.0+)$ ]] || die "volume must be between 0.0 and 1.0"
    edit --argjson v "$1" '.volume = $v' && echo "volume: $1" ;;
  packs)
    active="$(merged | jq -r .active_pack)"
    for d in "$root"/packs/*/; do
      n="$(basename "$d")"; m=" "; [ "$n" = "$active" ] && m="*"
      echo "$m $n ($(count_sounds "$d") sounds)"
    done ;;
  use)
    pack_exists "${1:-}" || die "no such pack: ${1:-} (see: fart packs)"
    edit --arg p "$1" '.active_pack = $p | .pack_rotation = []' && echo "pack: $1" ;;
  rotate)
    if [ "${1:-}" = off ]; then edit '.pack_rotation = []' && echo "rotation: off"
    else
      [ -n "${1:-}" ] || die "usage: fart rotate a,b,c | off"
      [[ "$1" != ,* && "$1" != *, && "$1" != *,,* ]] || die "empty pack name in list"
      IFS=',' read -r -a list <<<"$1"
      for p in "${list[@]}"; do pack_exists "$p" || die "no such pack: $p"; done
      edit --arg l "$1" '.pack_rotation = ($l | split(","))' && echo "rotation: $1"
    fi ;;
  category)
    name_ok "${1:-}" || die "usage: fart category <name> on|off"
    case "${2:-}" in
      on)  edit --arg c "$1" '.categories[$c] = true'  && echo "$1: on" ;;
      off) edit --arg c "$1" '.categories[$c] = false' && echo "$1: off" ;;
      *) die "usage: fart category <name> on|off" ;;
    esac ;;
  annoyed)
    [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]] || die "usage: fart annoyed <count> <seconds>"
    edit --argjson n "$1" --argjson w "$2" '.annoyed_threshold = $n | .annoyed_window_seconds = $w' && echo "annoyed: $1 prompts / $2 s" ;;
  notify)
    sub="${1:-}"; shift || true
    case "$sub" in
      desktop)
        case "${1:-}" in
          on)  edit '.notifications.desktop = true'  && echo "desktop notifications: on" ;;
          off) edit '.notifications.desktop = false' && echo "desktop notifications: off" ;;
          *) die "usage: fart notify desktop on|off" ;;
        esac ;;
      ntfy)
        [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "usage: fart notify ntfy <topic> [server]  (topic: letters, digits, _ -)"
        server="${2:-https://ntfy.sh}"; [[ "$server" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || die "bad server URL"
        [[ "$server" == http://* ]] && echo "warning: plain http: your topic name (it acts as a password) travels unencrypted" >&2
        edit --arg t "$1" --arg s "$server" '.notifications.ntfy = {topic: $t, server: $s}' && echo "ntfy: $server/$1" ;;
      telegram)
        [[ "${1:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "usage: fart notify telegram <bot_token> <chat_id>  (bad token format)"
        [[ "${2:-}" =~ ^(-?[0-9]+|@[A-Za-z0-9_]+)$ ]] || die "bad chat_id"
        edit --arg t "$1" --arg c "$2" '.notifications.telegram = {token: $t, chat_id: $c}' && echo "telegram: set" ;;
      pushover)
        [[ "${1:-}" =~ ^[A-Za-z0-9]+$ && "${2:-}" =~ ^[A-Za-z0-9]+$ ]] || die "usage: fart notify pushover <user_key> <app_token>"
        edit --arg u "$1" --arg t "$2" '.notifications.pushover = {user: $u, token: $t}' && echo "pushover: set" ;;
      categories)
        [[ "${1:-}" =~ ^[A-Za-z0-9_,-]+$ ]] || die "usage: fart notify categories a,b,c"
        edit --arg l "$1" '.notifications.categories = ($l | split(","))' && echo "notify categories: $1" ;;
      off)
        edit '.notifications.desktop = false | .notifications.ntfy.topic = "" | .notifications.telegram = {token:"",chat_id:""} | .notifications.pushover = {user:"",token:""}' && echo "notifications: off" ;;
      *) die "usage: fart notify desktop|ntfy|telegram|pushover|categories|off" ;;
    esac ;;
  test)
    c="${1:-stop}"; name_ok "$c" || die "bad category"
    [ -z "${2:-}" ] || name_ok "$2" || die "bad event"
    FART_SYNC="${FART_SYNC:-}" "$root/play.sh" "$c" "${2:-}" </dev/null; echo "played: $c${2:+ (event $2)}" ;;
  status)
    merged | jq -r '
      "claude-fart-ping: \(if .enabled then "ON" else "OFF" end)",
      "volume: \(.volume)",
      "pack: \(.active_pack)\(if (.pack_rotation|length) > 0 then "  rotation: " + (.pack_rotation|join(",")) else "" end)",
      "muted categories: \([.categories | to_entries[] | select(.value == false) | .key] | if length == 0 then "none" else join(",") end)",
      "annoyed: \(.annoyed_threshold) prompts / \(.annoyed_window_seconds)s",
      "notifications: desktop=\(.notifications.desktop) ntfy=\(if .notifications.ntfy.topic != "" then "on" else "off" end) telegram=\(if .notifications.telegram.token != "" then "on" else "off" end) pushover=\(if .notifications.pushover.token != "" then "on" else "off" end)",
      "notify categories: \(.notifications.categories | join(","))"' ;;
  *) usage >&2; exit 1 ;;
esac
