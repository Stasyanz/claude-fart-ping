#!/bin/bash
# Removes claude-fart-ping hooks (only ours) from Claude Code settings and the `fart` link.
#   uninstall.sh           hooks + link
#   uninstall.sh --purge   also delete the install folder (only the standard ~/.claude/claude-fart-ping)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
resolve() {
  local p="$1" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  echo "$p"
}
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
BIN_DIR="${FART_BIN_DIR:-$HOME/.local/bin}"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || die "jq is required"

target="$(resolve "$SETTINGS")"
if [ -f "$target" ]; then
  jq empty "$target" 2>/dev/null || die "$SETTINGS is not valid JSON, not touching it"
  jq -e '
    type == "object"
    and ((.hooks == null) or ((.hooks | type) == "object"
         and (.hooks | all(.[]; type == "array" and all(.[]; type == "object" and ((.hooks // []) | type) == "array")))))
  ' "$target" >/dev/null || die "unexpected shape of \"hooks\" in $SETTINGS, not touching it"
  [ -e "$target.bak-fart" ] || cp -p "$target" "$target.bak-fart"
  tmp="$(mktemp "$target.XXXXXX")"; trap 'rm -f "${tmp:-}"' EXIT
  jq '
    def mine: ((.command // "") | tostring | (contains("FART_PING=1") or contains("claude-fart-ping/play.sh")));
    def strip: map(if (.hooks | type) == "array" then (.hooks |= map(select(mine | not))) else . end)
               | map(select((.hooks | type) != "array" or (.hooks | length) > 0));
    if .hooks then
      .hooks |= (with_entries(.value |= strip) | with_entries(select(.value | length > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$target" > "$tmp"
  jq empty "$tmp" || die "generated settings are invalid, aborting"
  chmod "$(file_mode "$target")" "$tmp"
  mv "$tmp" "$target"
  echo "hooks removed from $SETTINGS (backup of the pre-install state: $target.bak-fart)"
fi

if [ -L "$BIN_DIR/fart" ]; then
  cur="$(readlink "$BIN_DIR/fart")"
  if [ "$cur" = "$self/fart.sh" ] || [[ "$cur" == */claude-fart-ping/fart.sh ]]; then
    rm -f "$BIN_DIR/fart"; echo "removed $BIN_DIR/fart"
  fi
fi

if [ "${1:-}" = "--purge" ]; then
  std="${FART_PING_DIR:-$CLAUDE_DIR/claude-fart-ping}"
  if [ -d "$std" ] && [ "$(cd "$std" && pwd -P)" = "$(cd "$self" && pwd -P)" ]; then
    rm -rf "$self"; echo "deleted $self"
  else
    echo "not deleting $self (not the standard install folder $std); remove it by hand if you want"
  fi
fi
