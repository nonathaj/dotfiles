# herdr plugins

Declarative plugin set for [herdr](https://herdr.dev), managed by
[herdr-lazy](https://github.com/natori-hrj/herdr-lazy).

- `plugins.list` — the plugins I want, one `owner/repo` per line. Edit by hand or
  with `herdr-lazy add` / `remove`, or from the manage pane. **This is the single
  authority.** It is what gets committed and what reproduces the set elsewhere.
- `plugins.lock` — the commit each one resolved to, rewritten on every `sync`.
  Local tool state, gitignored on purpose: the policy is "attempt my list and
  take what is current," and a committed lock would fight that, since `sync` and
  `install` both restore drifted pins. Do not check it in.

## Why it lives here and not in `dot_config/`

herdr-lazy owns these files and writes to them (`add`, `remove`, `sync`, `lock`).
If chezmoi rendered them into `$HOME`, every plugin change would show up as
drift and need a `chezmoi re-add`. So they stay in the source repo, `herdr` is
listed in `.chezmoiignore`, and herdr-lazy is pointed straight at them with
`HERDR_LAZY_LIST`. chezmoi versions them; it does not deploy them.

## Setting up a new machine

1. Install herdr, then `herdr plugin install natori-hrj/herdr-lazy`.
   On Windows this builds from source and needs a Rust toolchain.
2. Point herdr-lazy at this file. On macOS/Linux the export itself *is* carried
   by this repo, as `dot_config/shell/herdr.sh.tmpl` → `~/.config/shell/herdr.sh`.
   All that is left by hand is one stable line in your shell rc, which never has
   to change again:

   ```sh
   # macOS / Linux — in ~/.bashrc (or ~/.zshrc)
   [ -f ~/.config/shell/herdr.sh ] && . ~/.config/shell/herdr.sh
   ```

   ```powershell
   # Windows — still manual; an env var is not a file chezmoi can render
   [Environment]::SetEnvironmentVariable('HERDR_LAZY_LIST',
     "$env:USERPROFILE\.local\share\chezmoi\herdr\plugins.list", 'User')
   ```

3. Restart herdr, then `herdr-lazy install` to install whatever in the list is
   missing. Avoid `restore` — it converges to the local lockfile rather than to
   the list, which is the opposite of the intent here.

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

Carried by this repo as `dot_config/herdr/config.toml.tmpl`, which gates the
action id on `.chezmoi.os`. The binding is an array of tables, not a map —
`[keys.command]` fails validation with *invalid type: map, expected a sequence*:

```toml
[[keys.command]]
key = "prefix+shift+L"
command = "herdr-lazy.manage"
```

Check it with `herdr config check`. Note that chezmoi only renders this one file
into `~/.config/herdr/`; the rest of that directory is herdr's own runtime state
(sockets, logs, installed plugins) and is not managed.
