#!/bin/bash
# Tests for play.sh / install.sh / uninstall.sh.
# Uses a temp CLAUDE_CONFIG_DIR and a fake audio player: never touches real settings, never makes noise.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/claude" FART_NO_SOUND=1
S="$CLAUDE_CONFIG_DIR/settings.json"
fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# number of events that have one of our hooks
ours() { jq '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | contains("FART_PING=1")))] | length' "$S"; }
has()  { jq -e --arg e "$1" '.hooks[$e] | length > 0' "$S" >/dev/null 2>&1; }

# ---------- play.sh (fake afplay records the file it was asked to play)
mkdir -p "$T/bin" "$T/p/sounds/stop" "$T/p/sounds/other"
cat > "$T/bin/afplay" <<'FAKE'
#!/bin/bash
echo "${@: -1}" >> "$PLAYED"
FAKE
chmod +x "$T/bin/afplay"
cp "$ROOT/play.sh" "$T/p/"; touch "$T/p/sounds/stop/a.mp3" "$T/p/sounds/other/b.wav"
export PLAYED="$T/played"
run() { rm -f "$PLAYED"; PATH="$T/bin:$PATH" "$T/p/play.sh" "$@" </dev/null; local rc=$?; sleep 0.4; return $rc; }

check "play: no args exits 0, silent"        "run; [ ! -e '$PLAYED' ]"
check "play: category plays its own file"    "run stop; [ \"\$(cat '$PLAYED')\" = '$T/p/sounds/stop/a.mp3' ]"
check "play: unknown category falls back to pool" "run nope; grep -qE '/sounds/(stop/a.mp3|other/b.wav)$' '$PLAYED'"
check "play: path-like category uses pool only"   "run ../x; grep -qE '^$T/p/sounds/' '$PLAYED'"
check "play: prints nothing to stdout"       "[ -z \"\$(PATH='$T/bin:'\$PATH '$T/p/play.sh' stop </dev/null)\" ]"
rm -f "$T/p/sounds"/*/*; 
check "play: no sounds at all exits 0"       "run stop; [ ! -e '$PLAYED' ]"
check "play: always exit 0"                  "run stop"

# ---------- install, default mode
mkdir -p "$T/claude"
check "install: succeeds on fresh settings"  "'$ROOT/install.sh' >/dev/null 2>&1"
check "install: default hooks 26 events"     "[ \"\$(ours)\" = 26 ]"
check "install: Stop hooked"                 "has Stop"
check "install: SessionStart hooked"         "has SessionStart"
check "install: PostToolUseFailure hooked"   "has PostToolUseFailure"
check "install: PreToolUse NOT hooked (noisy)" "! has PreToolUse"
check "install: FileChanged never hooked"    "! has FileChanged"
check "install: command has category"        "[ \"\$(jq -r '.hooks.Stop[0].hooks[0].command' '$S' | awk '{print \$NF}')\" = stop ]"
check "install: async + timeout set"         "jq -e '.hooks.Stop[0].hooks[0] | .async == true and .timeout == 10' '$S' >/dev/null"

# ---------- idempotent, --all, back to default
"$ROOT/install.sh" >/dev/null 2>&1
check "install: idempotent"                  "[ \"\$(ours)\" = 26 ] && [ \"\$(jq '.hooks.Stop | length' '$S')\" = 1 ]"
"$ROOT/install.sh" --all >/dev/null 2>&1
check "install --all: 32 events"             "[ \"\$(ours)\" = 32 ]"
check "install --all: PreToolUse hooked"     "has PreToolUse"
check "install --all: FileChanged still not" "! has FileChanged"
"$ROOT/install.sh" >/dev/null 2>&1
check "install: back to default drops noisy" "[ \"\$(ours)\" = 26 ] && ! has PreToolUse"

# ---------- preserves foreign stuff
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}]}}' > "$S"
"$ROOT/install.sh" >/dev/null 2>&1
check "install: keeps other keys"            "[ \"\$(jq -r .model '$S')\" = sonnet ]"
check "install: keeps foreign Stop hook"     "jq -e '[.hooks.Stop[].hooks[].command] | index(\"echo other\")' '$S' >/dev/null"
check "install: keeps foreign PreToolUse"    "jq -e '[.hooks.PreToolUse[].hooks[].command] | index(\"echo pre\")' '$S' >/dev/null"
check "install: backup created"              "[ -f '$S.bak-fart' ]"

# ---------- invalid JSON
echo 'not json' > "$S"
check "install: refuses invalid JSON"        "! '$ROOT/install.sh' >/dev/null 2>&1"
check "install: invalid JSON left untouched" "[ \"\$(cat '$S')\" = 'not json' ]"

# ---------- uninstall
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$S"
"$ROOT/install.sh" --all >/dev/null 2>&1
"$ROOT/uninstall.sh" >/dev/null 2>&1
check "uninstall: none of ours left"         "[ \"\$(ours)\" = 0 ]"
check "uninstall: foreign hook kept"         "jq -e '[.hooks.Stop[].hooks[].command] == [\"echo other\"]' '$S' >/dev/null"
check "uninstall: empty events removed"      "[ \"\$(jq -c '.hooks | keys' '$S')\" = '[\"Stop\"]' ]"
echo '{"model":"sonnet"}' > "$S"; "$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
check "uninstall: removes empty hooks key"   "[ \"\$(jq -c . '$S')\" = '{\"model\":\"sonnet\"}' ]"

[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
