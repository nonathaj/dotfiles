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

## Add a new file

```bash
chezmoi add ~/.some/config/file
chezmoi git -- add -A
chezmoi git -- commit -m "add some config"
chezmoi git -- push
```
