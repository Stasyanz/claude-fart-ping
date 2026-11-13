#!/bin/bash
# claude-fart-ping installer.
#   install.sh          26 events (all except the noisy per-tool ones)
#   install.sh --all    every supported event (can be very noisy)
#   curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash
# or from a clone: ./install.sh
set -euo pipefail

REPO_URL="https://github.com/Stasyanz/claude-fart-ping.git"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
MODE=default
[ "${1:-}" = "--all" ] && MODE=all

die() { echo "error: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq, Debian/Ubuntu: apt install jq)"

# Run from a clone -> use it in place. Piped from curl -> clone to ~/.claude/claude-fart-ping.
src="${BASH_SOURCE[0]:-}"
if [ -n "$src" ] && [ -f "$(dirname "$src")/play.sh" ]; then
  DEST="$(cd "$(dirname "$src")" && pwd)"
else
  command -v git >/dev/null 2>&1 || die "git is required"
  DEST="${FART_PING_DIR:-$CLAUDE_DIR/claude-fart-ping}"
  if [ -d "$DEST/.git" ]; then
    git -C "$DEST" pull --ff-only --quiet
  else
    git clone --depth 1 --quiet "$REPO_URL" "$DEST"
  fi
fi
chmod +x "$DEST/play.sh"

if ! command -v afplay >/dev/null 2>&1 && ! command -v mpv >/dev/null 2>&1 \
   && ! command -v ffplay >/dev/null 2>&1 && ! command -v mpg123 >/dev/null 2>&1 \
   && ! command -v paplay >/dev/null 2>&1; then
  echo "warning: no audio player found (need afplay, mpv, ffplay, mpg123 or paplay)" >&2
fi

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON, not touching it"
cp "$SETTINGS" "$SETTINGS.bak-fart"

# Events to hook, from events.tsv (y = default, n = only with --all, x = never)
evs="$(awk -v m="$MODE" '!/^#/ && NF >= 3 && ($3 == "y" || (m == "all" && $3 == "n")) { print $1 " " $2 }' "$DEST/events.tsv" \
  | jq -R 'split(" ") | {event: .[0], cat: .[1]}' | jq -s .)"

# Idempotent: strip our old entries from every event, then add fresh ones.
tmp="$(mktemp)"
jq --arg dest "$DEST" --argjson evs "$evs" '
  def ours: (.hooks // []) | any(.[]; (.command // "") | (contains("FART_PING=1") or contains("claude-fart-ping/play.sh")));
  .hooks = ((.hooks // {}) | with_entries(.value |= map(select(ours | not))))
  | reduce $evs[] as $e (.;
      .hooks[$e.event] = ((.hooks[$e.event] // []) + [{"hooks":[{"type":"command","command":("FART_PING=1 " + $dest + "/play.sh " + $e.cat),"timeout":10,"async":true}]}]))
  | .hooks |= with_entries(select(.value | length > 0))
' "$SETTINGS" > "$tmp"
jq empty "$tmp" || { rm -f "$tmp"; die "generated settings are invalid, aborting"; }
mv "$tmp" "$SETTINGS"

echo "claude-fart-ping installed in $DEST"
echo "$(echo "$evs" | jq length) events hooked ($MODE) in $SETTINGS (backup: $SETTINGS.bak-fart)"
echo "Restart Claude Code (or run /hooks) to activate."
[ -n "${FART_NO_SOUND:-}" ] || "$DEST/play.sh" stop </dev/null || true
