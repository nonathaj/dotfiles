# herdr plugins

Declarative plugin set for [herdr](https://herdr.dev), managed by
[herdr-lazy](https://github.com/natori-hrj/herdr-lazy).

- `plugins.list` — the plugins I want, one `owner/repo` per line. Edit by hand or
  with `herdr-lazy add` / `remove`, or from the manage pane.
- `plugins.lock` — the commit each one is pinned to, rewritten on every `sync`.
  This is what reproduces the same set on another machine.

## Why it lives here and not in `dot_config/`

herdr-lazy owns these files and writes to them (`add`, `remove`, `sync`, `lock`).
If chezmoi rendered them into `$HOME`, every plugin change would show up as
drift and need a `chezmoi re-add`. So they stay in the source repo, `herdr` is
listed in `.chezmoiignore`, and herdr-lazy is pointed straight at them with
`HERDR_LAZY_LIST`. chezmoi versions them; it does not deploy them.

## Setting up a new machine

1. Install herdr, then `herdr plugin install natori-hrj/herdr-lazy`.
   On Windows this builds from source and needs a Rust toolchain.
2. Point herdr-lazy at this file — the one step that is *not* carried by this
   repo, because it is an environment variable rather than a file:

   ```sh
   # macOS / Linux — in your shell rc
   export HERDR_LAZY_LIST="$HOME/.local/share/chezmoi/herdr/plugins.list"
   ```

   ```powershell
   # Windows
   [Environment]::SetEnvironmentVariable('HERDR_LAZY_LIST',
     "$env:USERPROFILE\.local\share\chezmoi\herdr\plugins.list", 'User')
   ```

3. Restart herdr, then `herdr-lazy sync` — or `restore` to converge to the
   lockfile exactly rather than to the list.

**herdr must be restarted after setting the variable.** The server captures its
environment at startup and passes that to plugins, so until it restarts the
manage pane keeps using herdr-lazy's default config directory and silently
ignores this file. The CLI picks the variable up immediately; only the
herdr-spawned copy is stale.

## Keybinding

`prefix+shift+L` opens the manage pane, via `%APPDATA%\herdr\config.toml` on
Windows and `~/.config/herdr/config.toml` elsewhere. Note the action id differs
by platform — `herdr-lazy.manage-windows` on Windows, `herdr-lazy.manage`
elsewhere — because herdr rejects duplicate action ids even across platforms
that cannot overlap.
