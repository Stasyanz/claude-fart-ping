# 💨 claude-fart-ping

Fart sounds for [Claude Code](https://claude.com/claude-code) hooks. Claude finishes a reply, asks for permission, fails, starts a session, compacts context — and lets you know. Loudly.

Covers **all of Claude Code's hook events** (see [`events.tsv`](events.tsv)), grouped into sound categories:

| Category | Events (examples) |
|---|---|
| `stop` | `Stop`, `SubagentStop`, `TaskCompleted` |
| `notification` | `Notification`, `Elicitation`, `TeammateIdle` |
| `permission` | `PermissionRequest`, `PermissionDenied` |
| `error` | `PostToolUseFailure`, `StopFailure` |
| `start` | `SessionStart`, `SubagentStart`, `TaskCreated`, `WorktreeCreate` |
| `end` | `SessionEnd`, `WorktreeRemove` |
| `prompt` | `UserPromptSubmit`, `UserPromptExpansion` |
| `compact` | `PreCompact`, `PostCompact` |
| `misc` | `ConfigChange`, `DirectoryAdded`, `PreModelSwitch`, `PostModelSwitch`, … |
| `tool` | `PreToolUse`, `PostToolUse`, `PostToolBatch`, `MessageDisplay` (noisy, opt-in) |

A random clip from `packs/<pack>/<category>/` is played each time, never the same one twice in a row. A category without its own sounds (everything except `stop`, `notification`, `permission` for now) plays a random clip from the pack.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash
```

Then restart Claude Code (or run `/hooks`). That's it.

The installer clones the repo to `~/.claude/claude-fart-ping`, adds hooks to `~/.claude/settings.json` (backup saved as `settings.json.bak-fart`), and plays a test sound. It's safe to re-run: no duplicate hooks, your other hooks and settings are untouched.

By default it hooks 26 events and skips the six that fire constantly (`PreToolUse`, `PostToolUse`, `PostToolBatch`, `MessageDisplay`, `CwdChanged`, `InstructionsLoaded`) — Claude makes dozens of tool calls per reply, so you would get dozens of farts. Want everything anyway?

```bash
curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash -s -- --all
```

(`FileChanged` is never hooked: it needs explicit file names.) Re-running the installer with or without `--all` switches between the modes.

**Requirements:** `jq`, `git`, and an audio player — `afplay` on macOS (built in); on Linux one of `mpv`, `ffplay`, `mpg123`, `paplay`.

Prefer to look first? `git clone https://github.com/Stasyanz/claude-fart-ping && cd claude-fart-ping && ./install.sh`

## Uninstall

```bash
~/.claude/claude-fart-ping/uninstall.sh --purge
```

Removes only the claude-fart-ping hooks and the `fart` link; `--purge` also deletes the folder.

## Control it: the `fart` command

The installer links `fart` into `~/.local/bin` (if that folder exists; otherwise use `~/.claude/claude-fart-ping/fart.sh`).

```bash
fart status                    # current settings
fart toggle                    # mute / unmute everything (also: fart on, fart off)
fart volume 0.4                # 0.0-1.0
fart category error off        # mute one category (stop, error, spam, ...)
fart packs                     # list sound packs
fart use <pack>                # switch pack
fart rotate default,other      # random pack on every play (fart rotate off)
fart annoyed 3 10              # 3+ prompts within 10 s -> "annoyed" sound (0 = off)
fart test stop                 # play a sound now
```

Settings live in `config.json` next to the scripts (defaults in `config.default.json`). `FART_VOLUME=0.9` in the environment overrides the volume.

**Annoyed mode:** send prompts too fast (default: 3 within 10 s) and the `prompt` hook plays the `spam` category instead (falls back to `stop` clips until you add `packs/<pack>/spam/`).

### Notifications

Off by default. Texts are fixed (“Claude finished”, “Claude needs your permission”, …): no project names, prompts or file paths leave your machine.

```bash
fart notify desktop on                      # macOS / notify-send
fart notify ntfy my-secret-topic            # https://ntfy.sh (or: ... my-topic https://my.server)
fart notify telegram <bot_token> <chat_id>
fart notify pushover <user_key> <app_token>
fart notify categories stop,permission      # default: stop,notification,permission,error
fart notify off
```

Push tokens are stored in `config.json` (chmod 600, git-ignored) and passed to `curl` through stdin, not on the command line.

### Sound packs

A pack is just a folder: `packs/<name>/<category>/*.mp3` (also `.wav`, `.m4a`, `.aiff`). Create `packs/mypack/stop/`, drop clips in, run `fart use mypack`. Short clips (< 3 s) work best.

### Other

- **Which events:** edit [`events.tsv`](events.tsv) (`y` default, `n` only with `--all`, `x` never) and re-run `./install.sh`.
- **Manual setup:** see `hooks.example.json`.
- **Safe on every event:** `play.sh` always exits 0 and prints nothing, so it can't block Claude or leak text into its context (some events feed stdout to Claude).

Using [peon-ping](https://github.com/PeonPing/peon-ping) too? Both will play on the same events. Pause one with its toggle.

## Sounds

The clips in `packs/default/` are cut from the YouTube video "Epic Fart #2 - Director's Cut (No Talking)"

## Development

```bash
bash tests/test.sh
```

75 checks (engine, config, packs, notifications, CLI, installer). They use a temp directory with fake `afplay`/`curl`/`osascript`: silent, offline, and your real `settings.json` and `~/.local/bin` are never touched.

## License

Code: MIT. Sounds: see above.
