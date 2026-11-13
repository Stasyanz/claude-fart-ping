#!/bin/bash
# Removes claude-fart-ping hooks from Claude Code settings. Add --purge to delete ~/.claude/claude-fart-ping too.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
MARKER="claude-fart-ping/play.sh"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || { echo "error: $SETTINGS is not valid JSON" >&2; exit 1; }
  cp "$SETTINGS" "$SETTINGS.bak-fart"
  tmp="$(mktemp)"
  jq --arg marker "$MARKER" '
    def ours: (.hooks // []) | any(.[]; (.command // "") | contains($marker));
    if .hooks then
      .hooks |= (with_entries(.value |= map(select(ours | not))) | with_entries(select(.value | length > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp"
  jq empty "$tmp" && mv "$tmp" "$SETTINGS"
  echo "hooks removed from $SETTINGS (backup: $SETTINGS.bak-fart)"
fi

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CLAUDE_DIR/claude-fart-ping"
  echo "deleted $CLAUDE_DIR/claude-fart-ping"
fi
