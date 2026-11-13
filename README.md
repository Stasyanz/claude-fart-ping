# 💨 claude-fart-ping

Fart sounds for [Claude Code](https://claude.com/claude-code) hooks. Claude finishes a reply, asks for permission, or waits for you — and lets you know. Loudly.

| Event | Hook | Folder |
|---|---|---|
| Claude finished responding | `Stop` | `sounds/stop/` |
| Claude is waiting for you | `Notification` | `sounds/notification/` |
| Permission request | `PermissionRequest` | `sounds/permission/` |

A random file from the folder is played each time.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Stasyanz/claude-fart-ping/main/install.sh | bash
```

Then restart Claude Code (or run `/hooks`). That's it.

The installer clones the repo to `~/.claude/claude-fart-ping`, adds three hooks to `~/.claude/settings.json` (backup saved as `settings.json.bak-fart`), and plays a test sound. It's safe to re-run: no duplicate hooks, your other hooks and settings are untouched.

**Requirements:** `jq`, `git`, and an audio player — `afplay` on macOS (built in); on Linux one of `mpv`, `ffplay`, `mpg123`, `paplay`.

Prefer to look first? `git clone https://github.com/Stasyanz/claude-fart-ping && cd claude-fart-ping && ./install.sh`

## Uninstall

```bash
~/.claude/claude-fart-ping/uninstall.sh --purge
```

Removes only the claude-fart-ping hooks; `--purge` also deletes the folder.

## Configure

- **Volume:** `FART_VOLUME=1.0` (0.0–1.0, default 0.7). Set it in the `env` section of `settings.json`.
- **Your own sounds:** drop `.wav`, `.mp3`, `.m4a` or `.aiff` files into the `sounds/<category>/` folders. Short clips (< 3 s) work best.
- **Manual setup:** see `hooks.example.json`.

Using [peon-ping](https://github.com/PeonPing/peon-ping) too? Both will play on the same events. Pause one with its toggle.

## Sounds

The clips in `sounds/` are cut from the YouTube video "Epic Fart #2 - Director's Cut (No Talking)" by iFart. They are not mine and are not covered by the MIT license. If you are the rights holder and want them removed, open an issue and they'll be gone.

## Development

```bash
bash tests/test.sh
```

Tests run against a temporary config directory and never touch your real `settings.json`.

## License

Code: MIT. Sounds: see above.
