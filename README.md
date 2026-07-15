# dotfiles

Personal configuration files managed with [chezmoi](https://www.chezmoi.io/).

## Install chezmoi

**Windows:**
```powershell
winget install twpayne.chezmoi
```

**Linux:**
```bash
sh -c "$(curl -fsLS get.chezmoi.io)"
```

See [chezmoi install docs](https://www.chezmoi.io/install/) for other methods.

## Set up a new machine

Install chezmoi and apply dotfiles in one command:

```bash
chezmoi init --apply nonathaj/dotfiles
```

## Pull changes on an existing machine

```bash
chezmoi update
```

## Push local changes to the repo

After editing a managed file (e.g. `~/.claude/statusline.sh` or `~/.cursor/statusline.sh`):

```bash
# Re-add the changed file to chezmoi's source
chezmoi add ~/.claude/statusline.sh
chezmoi add ~/.cursor/statusline.sh

# Commit and push
chezmoi git -- add -A
chezmoi git -- commit -m "describe your change"
chezmoi git -- push
```

## Status lines

Shared bash scripts (Claude Code, Cursor CLI, Antigravity CLI). Layout matches Claude Code: project/git lines + session info (context bar, tokens). Claude adds ccburn usage limits when installed.

| Tool | Script | Config |
|------|--------|--------|
| Claude Code | `~/.claude/statusline.sh` | `~/.claude/settings.json` |
| Cursor CLI | `~/.cursor/statusline.sh` | chezmoi `modify_` → `~/.cursor/cli-config.json` |
| Antigravity CLI | `~/.gemini/antigravity-cli/statusline.sh` | chezmoi `modify_` → `~/.gemini/antigravity-cli/settings.json` |

**Linux / macOS:** run `statusline.sh` directly (executable + shebang).

**Windows:** Cursor and Antigravity use a `statusline.cmd` wrapper that finds Git Bash dynamically; bare `.sh` paths open in VS Code or fail under PowerShell.

## tmux / psmux

One shared config drives both [tmux](https://github.com/tmux/tmux) (Linux/macOS) and
[psmux](https://github.com/psmux/psmux) (native Windows tmux). The body lives in
`.chezmoitemplates/tmux.conf`; two thin wrappers include it and route to each OS's
config path. OS-specific bits (shell, clipboard, reload path) are gated inside the
shared body with `{{ if eq .chezmoi.os "windows" }}`.

| Platform | Target file | Source |
|----------|-------------|--------|
| Windows (psmux) | `~/.psmux.conf` | `dot_psmux.conf.tmpl` → `.chezmoitemplates/tmux.conf` |
| Linux/macOS (tmux) | `~/.config/tmux/tmux.conf` | `dot_config/tmux/tmux.conf.tmpl` → `.chezmoitemplates/tmux.conf` |

**Edit the shared config:** change `.chezmoitemplates/tmux.conf`, then `chezmoi apply`.
Reload a running session with `prefix + r`.

### Gotcha: no trailing comments on values

psmux parses the *entire rest of the line* as an option's value, so this silently
sets `escape-time` to the invalid string `10 # snappier`, and the setting never applies:

```tmux
set -g escape-time 10   # snappier   <-- BROKEN on psmux
```

Keep comments on their own line. Real tmux tolerates trailing comments; psmux does not.
Note that psmux only warns on *unknown* options — a bad *value* on a known option is a
quiet no-op. Verify with `psmux new-session -d -s t; psmux show-options -g`
(`psmux -f <file> start-server` does **not** surface config warnings).

### Plugins

`prefix + I` install · `prefix + U` update · `prefix + M` clean ·
`prefix + C-s` save session · `prefix + C-r` restore session

Plugins are declared once in the shared config; the namespace and bootstrap path are
resolved per-OS by template (`tmux-plugins/tmux-*` + tpm on Linux,
`psmux-plugins/psmux-*` + ppm on Windows). psmux's plugins are PowerShell
reimplementations that live in the `psmux/psmux-plugins` monorepo.

**One-time bootstrap per machine** (the plugin manager can't install itself):

```bash
# Linux/macOS
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

```powershell
# Windows
git clone https://github.com/psmux/psmux-plugins.git "$env:TEMP\psmux-plugins"
Copy-Item "$env:TEMP\psmux-plugins\ppm" "$env:USERPROFILE\.psmux\plugins\ppm" -Recurse
Remove-Item "$env:TEMP\psmux-plugins" -Recurse -Force
```

Then start a session and press `prefix + I`. Until the manager is bootstrapped, the
`run` line fails **silently** and plugins are inert no-ops — a missing manager looks
identical to a working config.

## Add a new file

```bash
chezmoi add ~/.some/config/file
chezmoi git -- add -A
chezmoi git -- commit -m "add some config"
chezmoi git -- push
```
