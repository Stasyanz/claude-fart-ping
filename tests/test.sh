#!/bin/bash
# Smoke tests for install.sh / uninstall.sh / play.sh. Uses a temp CLAUDE_CONFIG_DIR, never touches real settings.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/claude" FART_NO_SOUND=1
S="$CLAUDE_CONFIG_DIR/settings.json"
fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
count() { jq "[.hooks.$1[]?.hooks[]? | select(.command | contains(\"claude-fart-ping/play.sh\"))] | length" "$S"; }

# --- play.sh
check "play.sh: no args exits 0"            "'$ROOT/play.sh' </dev/null"
check "play.sh: unknown category exits 0"   "'$ROOT/play.sh' nope </dev/null"
mkdir -p "$T/p/sounds/stop"; cp "$ROOT/play.sh" "$T/p/"
check "play.sh: empty dir exits 0"          "'$T/p/play.sh' stop </dev/null"

# --- install into fresh dir (no settings.json)
mkdir -p "$T/claude"
check "install: fresh settings"             "'$ROOT/install.sh' >/dev/null 2>&1"
check "install: Stop hook added"            "[ \"\$(count Stop)\" = 1 ]"
check "install: Notification hook added"    "[ \"\$(count Notification)\" = 1 ]"
check "install: PermissionRequest added"    "[ \"\$(count PermissionRequest)\" = 1 ]"

# --- idempotent
"$ROOT/install.sh" >/dev/null 2>&1
check "install: idempotent (still 1 Stop)"  "[ \"\$(count Stop)\" = 1 ]"

# --- preserves foreign hooks and keys
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$S"
"$ROOT/install.sh" >/dev/null 2>&1
check "install: keeps other keys"           "[ \"\$(jq -r .model '$S')\" = sonnet ]"
check "install: keeps foreign hook"         "[ \"\$(jq '[.hooks.Stop[].hooks[].command | select(. == \"echo other\")] | length' '$S')\" = 1 ]"
check "install: backup created"             "[ -f '$S.bak-fart' ]"

# --- invalid JSON is refused and untouched
echo 'not json' > "$S"
check "install: refuses invalid JSON"       "! '$ROOT/install.sh' >/dev/null 2>&1"
check "install: invalid JSON untouched"     "[ \"\$(cat '$S')\" = 'not json' ]"

# --- uninstall
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$S"
"$ROOT/install.sh" >/dev/null 2>&1
"$ROOT/uninstall.sh" >/dev/null 2>&1
check "uninstall: our Stop hook gone"       "[ \"\$(count Stop)\" = 0 ]"
check "uninstall: foreign hook kept"        "[ \"\$(jq '[.hooks.Stop[].hooks[].command | select(. == \"echo other\")] | length' '$S')\" = 1 ]"
check "uninstall: empty events removed"     "[ \"\$(jq '.hooks | keys' '$S' -c)\" = '[\"Stop\"]' ]"

[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
