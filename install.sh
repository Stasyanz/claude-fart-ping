#!/bin/bash
# claude-fart-ping installer.
#   curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash
# or from a clone: ./install.sh
set -euo pipefail

REPO_URL="https://github.com/Stasyanz/claude-fart-ping.git"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
MARKER="claude-fart-ping/play.sh"

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

# Idempotent: drop our old entries, then append fresh ones.
tmp="$(mktemp)"
jq --arg dest "$DEST" --arg marker "$MARKER" '
  def ours: (.hooks // []) | any(.[]; (.command // "") | contains($marker));
  def add(event; cat):
    .hooks[event] = ((.hooks[event] // []) | map(select(ours | not)))
    + [{"matcher":"","hooks":[{"type":"command","command":($dest + "/play.sh " + cat),"timeout":10,"async":true}]}];
  .hooks = (.hooks // {})
  | add("Stop"; "stop")
  | add("Notification"; "notification")
  | add("PermissionRequest"; "permission")
' "$SETTINGS" > "$tmp"
jq empty "$tmp" || { rm -f "$tmp"; die "generated settings are invalid, aborting"; }
mv "$tmp" "$SETTINGS"

echo "claude-fart-ping installed in $DEST"
echo "hooks added to $SETTINGS (backup: $SETTINGS.bak-fart)"
echo "Restart Claude Code (or run /hooks) to activate."
[ -n "${FART_NO_SOUND:-}" ] || "$DEST/play.sh" stop </dev/null || true
