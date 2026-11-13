#!/bin/bash
# Tests for play.sh / fart.sh / install.sh / uninstall.sh.
# Everything runs in a temp dir with fake afplay/curl/osascript: no noise, no network,
# and your real ~/.claude and ~/.local/bin are never touched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
t() { local name="$1"; shift; if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; fail=1; fi; }
not() { ! "$@"; }

# ---------- fakes
mkdir -p "$T/fake"
cat > "$T/fake/afplay" <<'F'
#!/bin/bash
echo "$*" >> "$PLAYED"
F
cat > "$T/fake/osascript" <<'F'
#!/bin/bash
echo "osascript $*" >> "$NOTIFIED"
F
cat > "$T/fake/curl" <<'F'
#!/bin/bash
echo "curl $*" >> "$NOTIFIED"
case " $* " in *" -K - "*) cat >> "$NOTIFIED" ;; esac
F
chmod +x "$T/fake"/*
export PLAYED="$T/played" NOTIFIED="$T/notified"
export FART_NO_SOUND=1 FART_BIN_DIR="$T/localbin"; mkdir -p "$FART_BIN_DIR"

# ---------- sandbox project copy
P="$T/p"; mkdir -p "$P"
cp "$ROOT/play.sh" "$ROOT/fart.sh" "$ROOT/config.default.json" "$P/"
mk() { mkdir -p "$(dirname "$P/packs/$1")"; : > "$P/packs/$1"; }
reset() { rm -rf "$P/.state" "$P/config.json" "$P/packs" "$PLAYED" "$NOTIFIED"
  mk default/stop/a.mp3; mk default/stop/b.mp3; mk default/prompt/p.mp3; mk default/error/e.mp3; mk b/stop/x.mp3; }
run() { rm -f "$PLAYED" "$NOTIFIED"; PATH="$T/fake:$PATH" "$P/play.sh" "$@" </dev/null; local rc=$?; sleep 0.8; return $rc; }
played() { cat "$PLAYED" 2>/dev/null; }
played_in() { played | grep -q "/packs/$1"; }
cfg() { echo "$1" > "$P/config.json"; }
fart() { PATH="$T/fake:$PATH" "$P/fart.sh" "$@" 2>/dev/null; }

# ---------- play: basics
reset
t "play: no args exits 0, plays nothing"      bash -c "! { rm -f '$PLAYED'; PATH='$T/fake:'\$PATH '$P/play.sh' </dev/null; sleep 0.8; [ -e '$PLAYED' ]; }"
run stop;     t "play: category plays its own pack folder" played_in default/stop/
run nope;     t "play: unknown category falls back to pool" played_in default/
run ../x;     t "play: path-like category uses pool only"   played_in default/
t "play: prints nothing on stdout"            bash -c "[ -z \"\$(PATH='$T/fake:'\$PATH '$P/play.sh' stop </dev/null)\" ]"
t "play: exits 0 always"                      run stop

# ---------- play: config
reset; cfg '{"enabled":false}'; run stop;       t "config: enabled=false is silent"  not test -e "$PLAYED"
reset; cfg '{"categories":{"stop":false}}'
run stop; t "config: muted category is silent"  not test -e "$PLAYED"
run error; t "config: other category still plays" test -s "$PLAYED"
reset; cfg '{"volume":0.3}'; run stop;          t "config: volume from config"       grep -q -- '-v 0.3' "$PLAYED"
reset; cfg '{"volume":0.3}'; FART_VOLUME=0.9 run stop; t "config: FART_VOLUME overrides" grep -q -- '-v 0.9' "$PLAYED"
reset; cfg '{"volume":"loud"}'; run stop;       t "config: invalid volume -> 0.7"    grep -q -- '-v 0.7' "$PLAYED"
reset; echo '{broken' > "$P/config.json"; run stop; t "config: broken config.json -> defaults" test -s "$PLAYED"

# ---------- play: anti-repeat
reset; prev=""; ok=1
for i in 1 2 3 4 5 6 7 8; do run stop; cur="$(played)"; [ "$cur" = "$prev" ] && ok=0; prev="$cur"; done
t "anti-repeat: never same clip twice in a row" test $ok = 1
reset; rm "$P/packs/default/stop/b.mp3"; run stop; run stop
t "anti-repeat: single clip still plays"        test -s "$PLAYED"

# ---------- play: packs
reset; cfg '{"active_pack":"b"}'; run stop;     t "pack: active_pack used"            played_in b/stop/
reset; cfg '{"active_pack":"missing"}'; run stop; t "pack: missing pack -> default"   played_in default/
reset; cfg '{"pack_rotation":["b"]}'; run stop;  t "pack: rotation picks from list"   played_in b/
reset; cfg '{"active_pack":"../etc"}'; run stop; t "pack: path-like pack name rejected" played_in default/
reset; rm -rf "$P/packs"; run stop;             t "pack: no packs at all exits 0"     not test -e "$PLAYED"

# ---------- play: annoyed
reset; run prompt; played_in default/prompt/ && p1=1; run prompt; played_in default/prompt/ && p2=1
run prompt
t "annoyed: first two prompts normal"           test "${p1:-0}${p2:-0}" = 11
t "annoyed: third prompt in window -> spam (stop clip)" played_in default/stop/
reset; cfg '{"annoyed_threshold":0}'; run prompt; run prompt; run prompt
t "annoyed: threshold 0 disables"               played_in default/prompt/
reset; cfg '{"categories":{"spam":false}}'; run prompt; run prompt; run prompt
t "annoyed: spam can be muted"                  not test -e "$PLAYED"

# ---------- notifications
reset; cfg '{"notifications":{"desktop":true}}'; run stop
t "notify: desktop on -> osascript"             grep -q 'Claude finished' "$NOTIFIED"
run prompt; t "notify: non-notify category skipped" not test -e "$NOTIFIED"
reset; run stop; t "notify: off by default"     not test -e "$NOTIFIED"
reset; cfg '{"notifications":{"ntfy":{"topic":"mytopic"}}}'; run stop
t "notify: ntfy url"                            grep -q 'https://ntfy.sh/mytopic' "$NOTIFIED"
reset; cfg '{"notifications":{"telegram":{"token":"123:ABC","chat_id":"42"}}}'; run stop
t "notify: telegram secrets via stdin"          grep -q 'bot123:ABC/sendMessage' "$NOTIFIED"
t "notify: telegram token not in argv"          not grep -q '^curl .*123:ABC' "$NOTIFIED"
reset; cfg '{"enabled":false,"notifications":{"desktop":true}}'; run stop
t "notify: disabled with enabled=false"         not test -e "$NOTIFIED"

# ---------- fart CLI
reset
t "fart: volume ok"                             fart volume 0.4
t "fart: volume stored"                         test "$(jq .volume "$P/config.json")" = 0.4
t "fart: volume out of range rejected"          not fart volume 5
t "fart: config.json is chmod 600"              test "$(stat -f %Lp "$P/config.json" 2>/dev/null || stat -c %a "$P/config.json")" = 600
fart toggle >/dev/null; t "fart: toggle off"    test "$(jq .enabled "$P/config.json")" = false
fart toggle >/dev/null; t "fart: toggle on"     test "$(jq .enabled "$P/config.json")" = true
t "fart: use unknown pack rejected"             not fart use nope
t "fart: use ../x rejected"                     not fart use ../x
fart rotate default,b >/dev/null; t "fart: rotate set" test "$(jq -c .pack_rotation "$P/config.json")" = '["default","b"]'
t "fart: rotate unknown rejected"               not fart rotate default,zzz
fart use b >/dev/null; t "fart: use sets pack, clears rotation" test "$(jq -c '[.active_pack,.pack_rotation]' "$P/config.json")" = '["b",[]]'
fart category error off >/dev/null; t "fart: category off" test "$(jq .categories.error "$P/config.json")" = false
fart category error on  >/dev/null; t "fart: category on"  test "$(jq .categories.error "$P/config.json")" = true
t "fart: category bad value rejected"           not fart category error maybe
t "fart: annoyed set"                           fart annoyed 5 20
t "fart: annoyed rejects junk"                  not fart annoyed x y
t "fart: notify ntfy bad topic rejected"        not fart notify ntfy 'a b;c'
t "fart: notify telegram bad token rejected"    not fart notify telegram 'x"y' 1
t "fart: notify telegram ok"                    fart notify telegram 123:ABC-def -100
t "fart: notify desktop on"                     fart notify desktop on
t "fart: status hides secrets"                  bash -c "! PATH='$T/fake:'\$PATH '$P/fart.sh' status | grep -q 'ABC-def'"
t "fart: status mentions telegram=on"           bash -c "PATH='$T/fake:'\$PATH '$P/fart.sh' status | grep -q 'telegram=on'"
fart notify off >/dev/null; t "fart: notify off clears" test "$(jq -r '.notifications.telegram.token' "$P/config.json")" = ""
reset; rm -f "$P/config.json"; fart packs >"$T/packs.out"; t "fart: packs lists packs"  grep -q 'default' "$T/packs.out"
t "fart: test plays"                            bash -c "rm -f '$PLAYED'; PATH='$T/fake:'\$PATH '$P/fart.sh' test stop >/dev/null; sleep 0.8; [ -s '$PLAYED' ]"
t "fart: unknown command fails"                 not fart frobnicate

# ---------- install / uninstall
export CLAUDE_CONFIG_DIR="$T/claude"; S="$CLAUDE_CONFIG_DIR/settings.json"; mkdir -p "$CLAUDE_CONFIG_DIR"
ours() { jq '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | contains("FART_PING=1")))] | length' "$S"; }
has()  { jq -e --arg e "$1" '.hooks[$e] | length > 0' "$S" >/dev/null 2>&1; }
t "install: succeeds on fresh settings"         "$ROOT/install.sh" >/dev/null 2>&1
t "install: default = 26 events"                test "$(ours)" = 26
t "install: Stop/SessionStart/PostToolUseFailure hooked" bash -c "$(declare -f has); S='$S'; has Stop && has SessionStart && has PostToolUseFailure"
t "install: PreToolUse not hooked (noisy)"      not has PreToolUse
t "install: FileChanged never hooked"           not has FileChanged
t "install: command ends with category"         test "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S" | awk '{print $NF}')" = stop
t "install: async + timeout"                    jq -e '.hooks.Stop[0].hooks[0] | .async == true and .timeout == 10' "$S" >/dev/null
t "install: fart symlink created"               test -L "$FART_BIN_DIR/fart"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: idempotent"                         test "$(ours)" = 26 -a "$(jq '.hooks.Stop | length' "$S")" = 1
"$ROOT/install.sh" --all >/dev/null 2>&1
t "install --all: 32 events"                    test "$(ours)" = 32
t "install --all: PreToolUse hooked"            has PreToolUse
"$ROOT/install.sh" >/dev/null 2>&1
t "install: back to default drops noisy"        test "$(ours)" = 26 -a "$(has PreToolUse; echo $?)" = 1
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}]}}' > "$S"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: keeps other keys"                   test "$(jq -r .model "$S")" = sonnet
t "install: keeps foreign hooks"                jq -e '([.hooks.Stop[].hooks[].command] | index("echo other")) and ([.hooks.PreToolUse[].hooks[].command] | index("echo pre"))' "$S" >/dev/null
t "install: backup created"                     test -f "$S.bak-fart"
echo 'not json' > "$S"
t "install: refuses invalid JSON"               bash -c "! '$ROOT/install.sh' >/dev/null 2>&1"
t "install: invalid JSON untouched"             test "$(cat "$S")" = 'not json'
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$S"
"$ROOT/install.sh" --all >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: none of ours left"                test "$(ours)" = 0
t "uninstall: foreign hook kept"                jq -e '[.hooks.Stop[].hooks[].command] == ["echo other"]' "$S" >/dev/null
t "uninstall: empty events removed"             test "$(jq -c '.hooks | keys' "$S")" = '["Stop"]'
t "uninstall: fart symlink removed"             not test -e "$FART_BIN_DIR/fart"
echo '{"model":"sonnet"}' > "$S"; "$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: drops empty hooks key"            test "$(jq -c . "$S")" = '{"model":"sonnet"}'

[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
