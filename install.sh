#!/bin/bash
# claude-fart-ping installer.
#   curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --all      # every supported event (very noisy)
# or from a clone: ./install.sh [--all]
set -euo pipefail

REPO_URL="${FART_REPO_URL:-https://github.com/Stasyanz/claude-fart-ping.git}"

die() { echo "error: $*" >&2; exit 1; }
# follow symlinks (macOS has no `readlink -f` on older versions)
resolve() {
  local p="$1" l
  while [ -L "$p" ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  echo "$p"
}
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# Everything runs inside main() so a truncated download cannot execute half a script.
main() {
  local MODE=default
  [ "${1:-}" = "--all" ] && MODE=all

  local CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local SETTINGS="$CLAUDE_DIR/settings.json"
  command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq, Debian/Ubuntu: apt install jq)"

  # Run from a clone -> use it in place. Piped from curl -> clone to ~/.claude/claude-fart-ping.
  local src="${BASH_SOURCE[0]:-}" DEST
  # when the script comes from a pipe, BASH_SOURCE[0] is not a real file: clone instead
  if [ -n "$src" ] && [ -f "$src" ] && [ -f "$(dirname "$src")/play.sh" ]; then
    DEST="$(cd "$(dirname "$src")" && pwd)"
  else
    command -v git >/dev/null 2>&1 || die "git is required"
    DEST="${FART_PING_DIR:-$CLAUDE_DIR/claude-fart-ping}"
    if [ -d "$DEST/.git" ]; then
      git -C "$DEST" pull --ff-only --quiet || die "could not update $DEST (local changes? put event overrides in events.local.tsv)"
    else
      git clone --depth 1 --quiet "$REPO_URL" "$DEST"
    fi
  fi
  chmod +x "$DEST/play.sh" "$DEST/fart.sh"

  if ! command -v afplay >/dev/null 2>&1 && ! command -v mpv >/dev/null 2>&1 \
     && ! command -v ffplay >/dev/null 2>&1 && ! command -v mpg123 >/dev/null 2>&1 \
     && ! command -v paplay >/dev/null 2>&1; then
    echo "warning: no audio player found (need afplay, mpv, ffplay, mpg123 or paplay)" >&2
  fi

  # settings.json may be a symlink (dotfiles managers): edit the real file, keep it a symlink.
  mkdir -p "$CLAUDE_DIR"
  local target; target="$(resolve "$SETTINGS")"
  if [ ! -f "$target" ]; then mkdir -p "$(dirname "$target")"; echo '{}' > "$target"; fi
  jq empty "$target" 2>/dev/null || die "$SETTINGS is not valid JSON, not touching it"
  jq -e '
    type == "object"
    and ((.hooks == null) or ((.hooks | type) == "object"
         and (.hooks | all(.[]; type == "array" and all(.[]; type == "object" and ((.hooks // []) | type) == "array")))))
  ' "$target" >/dev/null || die "unexpected shape of \"hooks\" in $SETTINGS (expected {event: [{hooks: [...]}]}), not touching it"
  if jq -e '.disableAllHooks == true' "$target" >/dev/null; then
    echo "warning: \"disableAllHooks\" is true in $SETTINGS: no hook will fire until you remove it" >&2
  fi
  # Keep the FIRST backup (the state before claude-fart-ping); re-runs must not overwrite it.
  [ -e "$target.bak-fart" ] || cp -p "$target" "$target.bak-fart"

  # Events: events.tsv, overridable per user in events.local.tsv (untracked, survives updates).
  # Never hook the "x" events; Worktree* are blocked here too even if someone overrides them,
  # because those hooks replace git's worktree handling and would break `claude --worktree`.
  local evs
  evs="$({ cat "$DEST/events.tsv"; [ -f "$DEST/events.local.tsv" ] && cat "$DEST/events.local.tsv"; true; } \
    | awk -v m="$MODE" '
        !/^#/ && NF >= 3 { st[$1] = $3; cat[$1] = $2 }
        END { for (e in st) if (e !~ /^(Worktree(Create|Remove)|FileChanged)$/ && (st[e] == "y" || (m == "all" && st[e] == "n"))) print e " " cat[e] }' \
    | sort | jq -R 'split(" ") | {event: .[0], cat: .[1]}' | jq -s .)"

  # Idempotent: strip our hooks (only ours, even inside a shared group) from every event, then add fresh ones.
  local tmp; tmp="$(mktemp "$target.XXXXXX")"; trap 'rm -f "${tmp:-}"' EXIT
  jq --arg dest "$DEST" --argjson evs "$evs" '
    def mine: ((.command // "") | tostring | (contains("FART_PING=1") or contains("claude-fart-ping/play.sh")));
    def strip: map(if (.hooks | type) == "array" then (.hooks |= map(select(mine | not))) else . end)
               | map(select((.hooks | type) != "array" or (.hooks | length) > 0));
    .hooks = ((.hooks // {}) | with_entries(.value |= strip))
    | reduce $evs[] as $e (.;
        .hooks[$e.event] = ((.hooks[$e.event] // []) + [{"hooks":[{"type":"command",
          "command":("FART_PING=1 " + ($dest + "/play.sh" | @sh) + " " + $e.cat + " " + $e.event),
          "timeout":10,"async":true}]}]))
    | .hooks |= with_entries(select(.value | length > 0))
  ' "$target" > "$tmp"
  jq empty "$tmp" || die "generated settings are invalid, aborting"
  chmod "$(file_mode "$target")" "$tmp"
  mv "$tmp" "$target"

  echo "claude-fart-ping installed in $DEST"
  echo "$(echo "$evs" | jq length) events hooked ($MODE) in $SETTINGS (first backup kept as $target.bak-fart)"

  # `fart` command: symlink into ~/.local/bin if it exists. Never replace somebody else's `fart`.
  local BIN_DIR="${FART_BIN_DIR:-$HOME/.local/bin}"
  if [ -d "$BIN_DIR" ]; then
    local cur=""; [ -L "$BIN_DIR/fart" ] && cur="$(readlink "$BIN_DIR/fart")"
    if [ ! -e "$BIN_DIR/fart" ] && [ ! -L "$BIN_DIR/fart" ]; then
      ln -s "$DEST/fart.sh" "$BIN_DIR/fart"
    elif [ "$cur" = "$DEST/fart.sh" ] || [[ "$cur" == */claude-fart-ping/fart.sh ]]; then
      ln -sfn "$DEST/fart.sh" "$BIN_DIR/fart"
    else
      echo "note: $BIN_DIR/fart already exists and is not ours; left alone. Use: $DEST/fart.sh status"
      cur="skip"
    fi
    if [ "$cur" != "skip" ]; then
      echo "command: fart (try: fart status)"
      case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not in your PATH" ;; esac
    fi
  else
    echo "command: no ~/.local/bin to link into; use: $DEST/fart.sh status  (or alias fart='$DEST/fart.sh')"
  fi
  echo "Restart Claude Code (or run /hooks) to activate."
  [ -n "${FART_NO_SOUND:-}" ] || "$DEST/play.sh" stop </dev/null || true
}

main "$@"
