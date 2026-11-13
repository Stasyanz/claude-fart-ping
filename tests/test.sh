#!/bin/bash
# Tests for play.sh / fart.sh / install.sh / uninstall.sh.
# Everything runs in a temp dir with fake afplay/curl/osascript and FART_SYNC=1 (player and notifier
# run in the foreground, so no sleeps and "nothing happened" checks are deterministic).
# No noise, no network; your real ~/.claude and ~/.local/bin are never touched.
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
export PLAYED="$T/played" NOTIFIED="$T/notified" FART_SYNC=1 FART_NO_SOUND=1
export FART_BIN_DIR="$T/localbin"; mkdir -p "$FART_BIN_DIR"
export PATH="$T/fake:$PATH"

# ---------- sandbox project copy
P="$T/p"; mkdir -p "$P"
cp "$ROOT/play.sh" "$ROOT/fart.sh" "$ROOT/config.default.json" "$P/"
mk() { mkdir -p "$(dirname "$P/packs/$1")"; : > "$P/packs/$1"; }
reset() { rm -rf "$P/.state" "$P/config.json" "$P/packs" "$PLAYED" "$NOTIFIED"
  mk default/stop/a.mp3; mk default/stop/b.mp3; mk default/prompt/p.mp3; mk default/error/e.mp3; mk b/stop/x.mp3; }
run()  { rm -f "$PLAYED" "$NOTIFIED"; "$P/play.sh" "$@" </dev/null; }
runk() { "$P/play.sh" "$@" </dev/null; }          # keep previous PLAYED/NOTIFIED
played() { cat "$PLAYED" 2>/dev/null; }
played_in() { played | grep -q "/packs/$1"; }
notified() { cat "$NOTIFIED" 2>/dev/null; }
pushes() { grep -c "Claude\|Something" "$NOTIFIED" 2>/dev/null; }
cfg() { echo "$1" > "$P/config.json"; }
fart() { "$P/fart.sh" "$@" 2>/dev/null; }

# ================= play: basics
reset
t "play: no args plays nothing"                 bash -c "rm -f '$PLAYED'; '$P/play.sh' </dev/null; [ ! -e '$PLAYED' ]"
run stop;  t "play: category plays its own folder" played_in default/stop/
run nope;  t "play: unknown category -> pool of the pack" played_in default/
t "play: prints nothing on stdout"              bash -c "[ -z \"\$('$P/play.sh' stop </dev/null)\" ]"
t "play: prints nothing on stderr"              bash -c "[ -z \"\$('$P/play.sh' stop 2>&1 >/dev/null </dev/null)\" ]"
t "play: exits 0"                               run stop
# path traversal must not escape the pack: plant real files outside it
mkdir -p "$P/packs/x" "$P/etc/stop"; : > "$P/packs/x/f.mp3"; : > "$P/etc/stop/s.mp3"; : > "$P/out.mp3"
run ../x;  t "traversal: category ../x stays in pack" bash -c "grep -q '/packs/default/' '$PLAYED' && ! grep -q '/packs/x/' '$PLAYED'"
cfg '{"active_pack":"../etc"}'; run stop
t "traversal: pack ../etc rejected"             bash -c "grep -q '/packs/default/' '$PLAYED' && ! grep -q '/etc/' '$PLAYED'"
reset; mkdir -p "$T/ext/start"; : > "$T/ext/start/s.mp3"; ln -s "$T/ext" "$P/packs/linked"; cfg '{"active_pack":"linked"}'
run start; t "symlinked pack: own category folder plays" grep -q 'packs/linked/start/s.mp3' "$PLAYED"
run zzz;   t "symlinked pack: pool fallback plays"       grep -q 'packs/linked/start/s.mp3' "$PLAYED"

# ================= play: config
reset; cfg '{"enabled":false}'; run stop;       t "config: enabled=false is silent"  not test -e "$PLAYED"
reset; cfg '{"categories":{"stop":false}}'; run stop
t "config: muted category is silent"            not test -e "$PLAYED"
run error; t "config: other category still plays" test -s "$PLAYED"
reset; cfg '{"volume":0.3}'; run stop;          t "config: volume from config"       grep -q -- '-v 0.3' "$PLAYED"
FART_VOLUME=0.9 run stop;                       t "config: FART_VOLUME overrides"    grep -q -- '-v 0.9' "$PLAYED"
reset; cfg '{"volume":"loud"}'; run stop;       t "config: invalid volume -> 0.7"    grep -q -- '-v 0.7' "$PLAYED"
reset; echo '{broken' > "$P/config.json"; run stop; t "config: broken config.json -> defaults" test -s "$PLAYED"
reset; cfg '{"annoyed_threshold":99999999999999999999}'; t "config: huge number is harmless (silent, exit 0)" bash -c "[ -z \"\$('$P/play.sh' prompt 2>&1 </dev/null)\" ]"

# ================= play: anti-repeat
reset; prev=""; ok=1
for i in 1 2 3 4 5 6 7 8; do run stop; cur="$(played)"; [ "$cur" = "$prev" ] && ok=0; prev="$cur"; done
t "anti-repeat: never same clip twice in a row" test $ok = 1
reset; rm "$P/packs/default/stop/b.mp3"; run stop; run stop
t "anti-repeat: single clip still plays"        test -s "$PLAYED"

# ================= play: packs
reset; cfg '{"active_pack":"b"}'; run stop;     t "pack: active_pack used"            played_in b/stop/
reset; cfg '{"active_pack":"missing"}'; run stop; t "pack: missing pack -> default"   played_in default/
reset; cfg '{"pack_rotation":["b"]}'; run stop;  t "pack: rotation picks from list"   played_in b/
reset; rm -rf "$P/packs"; run stop;             t "pack: no packs at all exits 0"     not test -e "$PLAYED"

# ================= play: annoyed
reset; run prompt; played_in default/prompt/ && p1=1; run prompt; played_in default/prompt/ && p2=1
run prompt
t "annoyed: first two prompts normal"           test "${p1:-0}${p2:-0}" = 11
t "annoyed: third prompt in window -> spam (stop clip)" played_in default/stop/
reset; cfg '{"annoyed_threshold":0}'; run prompt; run prompt; run prompt
t "annoyed: threshold 0 disables"               played_in default/prompt/
reset; cfg '{"categories":{"spam":false}}'; run prompt; run prompt; run prompt
t "annoyed: spam can be muted"                  not test -e "$PLAYED"
reset; for i in $(seq 20); do "$P/play.sh" prompt </dev/null & done; wait
t "annoyed: 20 parallel prompts all counted (no lost updates)" test "$(wc -l < "$P/.state/prompts" | tr -d ' ')" = 20

# ================= notifications (event-driven, throttled)
reset; cfg '{"notifications":{"desktop":true}}'; run stop Stop
t "notify: Stop + desktop on -> osascript"      grep -q 'Claude finished' "$NOTIFIED"
run stop;  t "notify: no event -> no notification" not test -e "$NOTIFIED"
reset; run stop Stop; t "notify: off by default" not test -e "$NOTIFIED"
reset; cfg '{"notifications":{"desktop":true}}'; run error PostToolUseFailure
t "notify: PostToolUseFailure never notifies"   not test -e "$NOTIFIED"
run error StopFailure; t "notify: StopFailure -> 'Something failed'" grep -q 'Something failed' "$NOTIFIED"
run permission PermissionDenied; t "notify: PermissionDenied never notifies" not test -e "$NOTIFIED"
for i in 1 2 3; do run prompt UserPromptSubmit; done; t "notify: prompt/spam never notifies" not test -e "$NOTIFIED"
reset; cfg '{"notifications":{"desktop":true}}'; run stop Stop; runk stop SubagentStop; runk stop Stop
t "throttle: repeated Stop -> one push"         test "$(pushes)" = 1
reset; cfg '{"notifications":{"desktop":true}}'; run permission PermissionRequest; runk notification Notification
t "throttle: PermissionRequest + Notification -> one push" test "$(pushes)" = 1
reset; cfg '{"notifications":{"desktop":true,"min_interval_seconds":0}}'; run stop Stop; runk stop Stop
t "throttle: interval 0 disables throttling"    test "$(pushes)" = 2
reset; cfg '{"notifications":{"desktop":true,"categories":["permission"]}}'; run stop Stop
t "notify: categories filter blocks stop"       not test -e "$NOTIFIED"
run permission PermissionRequest; t "notify: categories filter allows permission" grep -q 'needs your permission' "$NOTIFIED"
reset; cfg '{"notifications":{"ntfy":{"topic":"mytopic"}}}'; run stop Stop
t "notify: ntfy default server url"             grep -q 'url = "https://ntfy.sh/mytopic"' "$NOTIFIED"
reset; cfg '{"notifications":{"ntfy":{"topic":"mytopic","server":"https://ntfy.example.org/"}}}'; run stop Stop
t "notify: ntfy custom server"                  grep -q 'url = "https://ntfy.example.org/mytopic"' "$NOTIFIED"
reset; cfg '{"notifications":{"telegram":{"token":"123:ABC","chat_id":"42"}}}'; run stop Stop
t "notify: telegram url + chat via stdin"       bash -c "grep -q 'bot123:ABC/sendMessage' '$NOTIFIED' && grep -q 'chat_id=42' '$NOTIFIED'"
t "notify: telegram token not in argv"          not grep -q '^curl .*123:ABC' "$NOTIFIED"
reset; cfg '{"notifications":{"pushover":{"user":"u1","token":"t1"}}}'; run stop Stop
t "notify: pushover payload"                    bash -c "grep -q 'api.pushover.net' '$NOTIFIED' && grep -q 'token=t1' '$NOTIFIED' && grep -q 'user=u1' '$NOTIFIED'"
reset; cfg '{"enabled":false,"notifications":{"desktop":true}}'; run stop Stop
t "notify: disabled with enabled=false"         not test -e "$NOTIFIED"
# hand-edited config with curl-config injection attempts must not reach curl
bad() { reset; cfg "$1"; run stop Stop; not test -e "$NOTIFIED"; }
t "inject: telegram token with newline/directives" bad '{"notifications":{"telegram":{"token":"1:A\"\nurl = \"file:///etc/hosts#","chat_id":"1"}}}'
t "inject: telegram chat_id with quote"         bad '{"notifications":{"telegram":{"token":"1:A","chat_id":"1\"\noutput = \"/tmp/x"}}}'
t "inject: pushover with space/quote"           bad '{"notifications":{"pushover":{"user":"a b","token":"x\"y"}}}'
t "inject: ntfy topic with space"               bad '{"notifications":{"ntfy":{"topic":"a b"}}}'
t "inject: ntfy server as curl option"          bad '{"notifications":{"ntfy":{"topic":"ok","server":"-o/tmp/x"}}}'
t "inject: ntfy server with newline"            bad '{"notifications":{"ntfy":{"topic":"ok","server":"https://a.b\nurl = \"x"}}}'

# ================= fart CLI
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
t "fart: rotate trailing comma rejected"        not fart rotate 'default,'
fart use b >/dev/null; t "fart: use sets pack, clears rotation" test "$(jq -c '[.active_pack,.pack_rotation]' "$P/config.json")" = '["b",[]]'
fart category error off >/dev/null; t "fart: category off" test "$(jq .categories.error "$P/config.json")" = false
fart category error on  >/dev/null; t "fart: category on"  test "$(jq .categories.error "$P/config.json")" = true
t "fart: category bad value rejected"           not fart category error maybe
t "fart: annoyed set"                           fart annoyed 5 20
t "fart: annoyed rejects junk"                  not fart annoyed x y
t "fart: notify ntfy bad topic rejected"        not fart notify ntfy 'a b;c'
t "fart: notify ntfy bad server rejected"       not fart notify ntfy ok '-o/x'
t "fart: notify ntfy http warns"                bash -c "'$P/fart.sh' notify ntfy ok http://h.local 2>&1 >/dev/null | grep -q 'unencrypted'"
t "fart: notify telegram bad token rejected"    not fart notify telegram 'x"y' 1
t "fart: notify telegram ok"                    fart notify telegram 123:ABC-def -100
t "fart: notify pushover ok"                    fart notify pushover u1 t1
t "fart: notify categories"                     fart notify categories stop,permission
t "fart: notify desktop on"                     fart notify desktop on
t "fart: status hides secrets"                  bash -c "! '$P/fart.sh' status | grep -q 'ABC-def'"
t "fart: status mentions telegram=on"           bash -c "'$P/fart.sh' status | grep -q 'telegram=on'"
fart notify off >/dev/null; t "fart: notify off clears" test "$(jq -r '.notifications.telegram.token' "$P/config.json")" = ""
reset; rm -f "$P/config.json"; fart packs >"$T/packs.out"; t "fart: packs lists packs"  grep -q 'default' "$T/packs.out"
rm -f "$P/config.json"; fart help >/dev/null; t "fart: help does not create config.json" not test -e "$P/config.json"
t "fart: test plays"                            bash -c "rm -f '$PLAYED'; '$P/fart.sh' test stop >/dev/null; [ -s '$PLAYED' ]"
cfg '{"notifications":{"desktop":true}}'; rm -f "$NOTIFIED"; fart test stop Stop >/dev/null
t "fart: test <category> <event> notifies"      grep -q 'Claude finished' "$NOTIFIED"
t "fart: unknown command fails"                 not fart frobnicate
reset; echo '{}' > "$T/real.json"; ln -s "$T/real.json" "$P/config.json"; fart volume 0.2 >/dev/null
t "fart: symlinked config.json stays a symlink" bash -c "[ -L '$P/config.json' ] && [ \"\$(jq .volume '$T/real.json')\" = 0.2 ]"

# ================= install / uninstall
export CLAUDE_CONFIG_DIR="$T/claude"; S="$CLAUDE_CONFIG_DIR/settings.json"; mkdir -p "$CLAUDE_CONFIG_DIR"
ours() { jq '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command | contains("FART_PING=1")))] | length' "$S"; }
has()  { jq -e --arg e "$1" '.hooks[$e] | length > 0' "$S" >/dev/null 2>&1; }
t "install: succeeds on fresh settings"         "$ROOT/install.sh" >/dev/null 2>&1
t "install: default = 23 events"                test "$(ours)" = 23
t "install: Stop/SessionStart/PostToolUseFailure hooked" bash -c "$(declare -f has); S='$S'; has Stop && has SessionStart && has PostToolUseFailure"
t "install: PreToolUse not hooked (noisy)"      not has PreToolUse
t "install: FileChanged never hooked"           not has FileChanged
t "install: WorktreeCreate never hooked"        not has WorktreeCreate
t "install: WorktreeRemove never hooked"        not has WorktreeRemove
t "install: command ends with '<category> <Event>'" test "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S" | awk '{print $(NF-1) " " $NF}')" = "stop Stop"
t "install: async + timeout"                    jq -e '.hooks.Stop[0].hooks[0] | .async == true and .timeout == 10' "$S" >/dev/null
t "install: fart symlink created"               test -L "$FART_BIN_DIR/fart"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: idempotent"                         test "$(ours)" = 23 -a "$(jq '.hooks.Stop | length' "$S")" = 1
"$ROOT/install.sh" --all >/dev/null 2>&1
t "install --all: 30 events"                    test "$(ours)" = 30
t "install --all: PreToolUse hooked"            has PreToolUse
t "install --all: Worktree* and FileChanged still never" bash -c "$(declare -f has); S='$S'; ! has WorktreeCreate && ! has WorktreeRemove && ! has FileChanged"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: back to default drops noisy"        test "$(ours)" = 23 -a "$(has PreToolUse; echo $?)" = 1

# foreign hooks / other keys preserved; first backup kept
orig='{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"echo pre"}]}]}}'
rm -f "$S.bak-fart"; echo "$orig" > "$S"
"$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/install.sh" >/dev/null 2>&1
t "install: keeps other keys"                   test "$(jq -r .model "$S")" = sonnet
t "install: keeps foreign hooks"                jq -e '([.hooks.Stop[].hooks[].command] | index("echo other")) and ([.hooks.PreToolUse[].hooks[].command] | index("echo pre"))' "$S" >/dev/null
t "install: backup = original, survives re-install" test "$(cat "$S.bak-fart")" = "$orig"

# our hook sharing a group with a foreign one: only ours goes away
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"FART_PING=1 /x/claude-fart-ping/play.sh stop Stop"}]}]}}' > "$S"
"$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: shared group keeps foreign hook"  test "$(jq -c '[.hooks.Stop[].hooks[].command]' "$S")" = '["say done"]'
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"FART_PING=1 /x/claude-fart-ping/play.sh stop Stop"}]}]}}' > "$S"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: shared group keeps foreign hook"    jq -e '[.hooks.Stop[].hooks[].command] | index("say done")' "$S" >/dev/null
t "install: shared group: exactly one of ours"  test "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("FART_PING=1"))] | length' "$S")" = 1
echo '{"hooks":{"Stop":[{"matcher":"x"}]}}' > "$S"; "$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: keeps foreign group without .hooks" jq -e '.hooks.Stop[0].matcher == "x"' "$S" >/dev/null

# weird settings.json shapes are refused and left untouched
for shape in '{"hooks":"bad"}' '{"hooks":{"Stop":{"x":1}}}' '{"hooks":{"Stop":["str"]}}' '[]' '"s"' 'not json'; do
  echo "$shape" > "$S"
  t "install: refuses $shape" bash -c "! '$ROOT/install.sh' >/dev/null 2>&1 && [ \"\$(cat '$S')\" = '$shape' ]"
done
echo '{"disableAllHooks":true}' > "$S"
t "install: warns about disableAllHooks"        bash -c "'$ROOT/install.sh' 2>&1 >/dev/null | grep -q disableAllHooks"

# settings.json as a symlink (dotfiles): stays a symlink, mode preserved
mkdir -p "$T/dot"; echo '{"model":"x"}' > "$T/dot/settings.json"; chmod 644 "$T/dot/settings.json"
rm -f "$S" "$T/claude/settings.json.bak-fart"; ln -s "$T/dot/settings.json" "$S"
"$ROOT/install.sh" >/dev/null 2>&1
t "install: symlinked settings.json stays a symlink" test -L "$S"
t "install: real file behind symlink got the hooks"  test "$(jq '.hooks | length' "$T/dot/settings.json")" -gt 0
t "install: file mode preserved (644)"          test "$(stat -f %Lp "$T/dot/settings.json" 2>/dev/null || stat -c %a "$T/dot/settings.json")" = 644
t "install: no temp files left behind"          test -z "$(ls "$T/dot" | grep -v -e '^settings.json$' -e 'bak-fart')"
"$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: symlink survives, hooks gone"     bash -c "[ -L '$S' ] && [ \"\$(jq -c . '$T/dot/settings.json')\" = '{\"model\":\"x\"}' ]"
rm -f "$S"; echo '{}' > "$S"

# path with spaces: the generated command must really run through the shell
SP="$T/my dir/claude-fart-ping"; mkdir -p "$SP"
cp -R "$ROOT/play.sh" "$ROOT/fart.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/events.tsv" "$ROOT/config.default.json" "$ROOT/packs" "$SP/"
"$SP/install.sh" >/dev/null 2>&1
rm -f "$PLAYED"
t "install: path with spaces: hook command runs" bash -c "sh -c \"\$(jq -r '.hooks.Stop[0].hooks[0].command' '$S')\" </dev/null; [ -s '$PLAYED' ]"
printf 'PreToolUse tool y\nWorktreeCreate start y\nStop stop n\n' > "$SP/events.local.tsv"
"$SP/install.sh" >/dev/null 2>&1
t "events.local.tsv: enable an event"           has PreToolUse
t "events.local.tsv: disable an event"          not has Stop
t "events.local.tsv: cannot enable WorktreeCreate" not has WorktreeCreate
"$SP/uninstall.sh" >/dev/null 2>&1

# somebody else's `fart` is never touched
rm -f "$FART_BIN_DIR/fart"; printf '#!/bin/sh\necho mine\n' > "$FART_BIN_DIR/fart"; chmod +x "$FART_BIN_DIR/fart"
"$ROOT/install.sh" >/dev/null 2>&1; t "install: foreign fart binary left alone" test "$("$FART_BIN_DIR/fart")" = mine
"$ROOT/uninstall.sh" >/dev/null 2>&1; t "uninstall: foreign fart binary left alone" test "$("$FART_BIN_DIR/fart")" = mine
rm -f "$FART_BIN_DIR/fart"; ln -s /usr/bin/true "$FART_BIN_DIR/fart"
"$ROOT/install.sh" >/dev/null 2>&1; t "install: foreign fart symlink left alone" test "$(readlink "$FART_BIN_DIR/fart")" = /usr/bin/true
rm -f "$FART_BIN_DIR/fart"

# uninstall
echo '{"model":"sonnet","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$S"; rm -f "$S.bak-fart"
"$ROOT/install.sh" --all >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: none of ours left"                test "$(ours)" = 0
t "uninstall: foreign hook kept"                jq -e '[.hooks.Stop[].hooks[].command] == ["echo other"]' "$S" >/dev/null
t "uninstall: empty events removed"             test "$(jq -c '.hooks | keys' "$S")" = '["Stop"]'
t "uninstall: fart symlink removed"             not test -e "$FART_BIN_DIR/fart"
echo '{"model":"sonnet"}' > "$S"; "$ROOT/install.sh" >/dev/null 2>&1; "$ROOT/uninstall.sh" >/dev/null 2>&1
t "uninstall: drops empty hooks key"            test "$(jq -c . "$S")" = '{"model":"sonnet"}'
"$ROOT/uninstall.sh" --purge >/dev/null 2>&1
t "uninstall --purge: never deletes a non-standard folder" test -f "$ROOT/play.sh"

# curl | bash path: clone into the standard folder, update, purge
SRC="$T/srcrepo"; mkdir -p "$SRC"; cp -R "$ROOT/play.sh" "$ROOT/fart.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/events.tsv" "$ROOT/config.default.json" "$ROOT/packs" "$SRC/"
git -C "$SRC" init -q -b main && git -C "$SRC" add -A && git -C "$SRC" -c user.name=t -c user.email=t@example.com commit -q -m init
STD="$T/std/claude-fart-ping"; export FART_REPO_URL="file://$SRC" FART_PING_DIR="$STD"
echo '{}' > "$S"
t "curl|bash: clones and installs (even when cwd has a play.sh)" bash -c "cd '$ROOT' && bash -s < '$ROOT/install.sh' >/dev/null 2>&1 && [ -x '$STD/play.sh' ]"
t "curl|bash: hooks point to the clone"         bash -c "jq -r '.hooks.Stop[0].hooks[0].command' '$S' | grep -q \"$STD\""
t "curl|bash: second run updates in place"      bash -c "bash -s < '$ROOT/install.sh' >/dev/null 2>&1"
t "uninstall --purge: removes the standard folder" bash -c "'$STD/uninstall.sh' --purge >/dev/null 2>&1; [ ! -e '$STD' ]"
unset FART_REPO_URL FART_PING_DIR

[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
