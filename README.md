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

A random file from `sounds/<category>/` is played each time. A category without its own sounds (everything except `stop`, `notification`, `permission` for now) plays a random clip from any folder.

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

Removes only the claude-fart-ping hooks; `--purge` also deletes the folder.

## Configure

- **Volume:** `FART_VOLUME=1.0` (0.0–1.0, default 0.7). Set it in the `env` section of `settings.json`.
- **Your own sounds:** drop `.wav`, `.mp3`, `.m4a` or `.aiff` files into `sounds/<category>/` (create the folder for categories that don't have one yet). Short clips (< 3 s) work best.
- **Which events:** edit [`events.tsv`](events.tsv) (`y` default, `n` only with `--all`, `x` never) and re-run `./install.sh`.
- **Manual setup:** see `hooks.example.json`.
- **Safe on every event:** `play.sh` always exits 0 and prints nothing, so it can't block Claude or leak text into its context (some events feed stdout to Claude).

Using [peon-ping](https://github.com/PeonPing/peon-ping) too? Both will play on the same events. Pause one with its toggle.

## Sounds

The clips in `sounds/` are cut from the YouTube video "Epic Fart #2 - Director's Cut (No Talking)"

## Development

```bash
bash tests/test.sh
```

Tests run against a temporary config directory and never touch your real `settings.json`.

## License

Code: MIT. Sounds: see above.
