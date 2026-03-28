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

After editing a managed file (e.g. `~/.claude/statusline.sh`):

```bash
# Re-add the changed file to chezmoi's source
chezmoi add ~/.claude/statusline.sh

# Commit and push
chezmoi git -- add -A
chezmoi git -- commit -m "describe your change"
chezmoi git -- push
```

## Add a new file

```bash
chezmoi add ~/.some/config/file
chezmoi git -- add -A
chezmoi git -- commit -m "add some config"
chezmoi git -- push
```
