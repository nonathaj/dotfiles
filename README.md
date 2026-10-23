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

After editing a managed file (e.g. `~/.claude/statusline.cjs` or `~/.cursor/statusline.sh`):

```bash
# Re-add the changed file to chezmoi's source
chezmoi add ~/.claude/statusline.cjs
chezmoi add ~/.cursor/statusline.sh

# Commit and push
chezmoi git -- add -A
chezmoi git -- commit -m "describe your change"
chezmoi git -- push
```

## Windows app installs

`.chezmoiscripts/run_onchange_install-windows-apps.ps1.tmpl` installs a list of winget packages. It reruns automatically via `chezmoi apply`/`chezmoi update` whenever the script changes, and is idempotent (skips packages that are already installed), so it's safe to rerun any time.

## Status lines

Shared scripts (Claude Code, Cursor CLI, Antigravity CLI). Layout matches Claude Code: project/git lines + session info (context bar, tokens). Claude's is a Node script (one process per render, which matters on Windows); its context bar fills toward the auto-compact window rather than the full context window, and it adds ccburn usage limits when installed.

| Tool | Script | Config |
|------|--------|--------|
| Claude Code | `~/.claude/statusline.cjs` (needs Node) | `~/.claude/settings.json` |
| Cursor CLI | `~/.cursor/statusline.sh` | chezmoi `modify_` → `~/.cursor/cli-config.json` |
| Antigravity CLI | `~/.gemini/antigravity-cli/statusline.sh` | chezmoi `modify_` → `~/.gemini/antigravity-cli/settings.json` |
| oh-my-pi | — (native, no script) | chezmoi `modify_` → `~/.omp/agent/config.yml` |

**Linux / macOS:** run `statusline.sh` directly (executable + shebang).

**Windows:** Cursor and Antigravity use a `statusline.cmd` wrapper that finds Git Bash dynamically; bare `.sh` paths open in VS Code or fail under PowerShell.

oh-my-pi has no external statusline command hook — its status line is native preset/segment config. The `modify_` template sets a `custom` preset mirroring the shared layout (model+thinking level │ path+git │ context % │ ↑/↓ tokens │ session name), pipe separators, transparent background, and preserves omp's runtime keys (`modelRoles`, `setupVersion`, `shellPath`, …).

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

## Voice input (dictating to AI agents)

Push-to-talk dictation that types into whatever window has focus, so it works in
Claude Code, a terminal, an editor, or a browser alike. Everything runs locally:
no audio, transcript, or API key ever leaves the machine.

| Piece | What it does | Install |
|-------|--------------|---------|
| [Handy](https://github.com/cjpais/Handy) | Push-to-talk speech-to-text (Rust/Tauri, MIT) | `winget install cjpais.Handy` / `.deb`/`.rpm`/AppImage |
| [Ollama](https://ollama.com) | Serves the local model for the optional cleanup pass | `winget install Ollama.Ollama` / `install.sh` |

Both are installed by `run_once_install-voice-input.{ps1,sh}`, which is idempotent
and safe to re-run.

### Shortcuts

| Keys | Action |
|------|--------|
| `Ctrl+Space` (hold) | Record; release to transcribe and paste |
| `Ctrl+Shift+Space` (hold) | Same, then clean the transcript through the local LLM |
| `Escape` | Cancel the current recording |

`auto_submit` is deliberately off — dictated text lands in the prompt and waits for
you to press Enter. A half-heard instruction fired at an agent is worse than one
you glance at first.

### Models

| Role | Model | Size | Why |
|------|-------|------|-----|
| Transcription | `parakeet-tdt-0.6b-v2` | 451 MB | English-only; faster *and* more accurate than any Whisper variant |
| Transcription (fallback) | `turbo` (Whisper large-v3-turbo) | 1.5 GB | Multilingual, more robust to accents and noise |
| Cleanup pass | `llama3.2:3b` via Ollama | 2.0 GB | 0.78 s warm |

Handy holds **one active transcription model at a time** — there is no per-shortcut
model binding. Switch in Settings → Models; it hot-loads without a restart.

#### Gotcha: the cleanup model must not be a reasoning model

Measured on an RTX 2070 SUPER against the shipped cleanup prompt:

| Model | Warm latency | Completion tokens |
|-------|--------------|-------------------|
| `llama3.2:3b` | 0.78 s | 43 |
| `qwen2.5:3b-instruct` | 0.70 s | 40 (but failed to punctuate at all) |
| `qwen3:4b` | **62 s** | **5507** |

A reasoning model spends its entire budget thinking before emitting one cleaned
sentence, which makes an inline cleanup pass unusable. `/no_think` does **not**
fix it through the OpenAI-compatible endpoint — it only cut 5507 tokens to 4616.
Keep this a small *instruct* model.

### How the config is managed

`settings_store.json` is **owned by Handy at runtime** — it records model download
state, the last-seen release-notes version, and a per-machine microphone choice,
and it gains new keys on every release. So this is a `modify_` template that merges
our keys in and passes everything else through, rather than a file that replaces it.

| Platform | Target | Source |
|----------|--------|--------|
| Windows | `%APPDATA%\com.pais.handy\settings_store.json` | `AppData/Roaming/com.pais.handy/modify_settings_store.json` |
| Linux | `~/.config/com.pais.handy/settings_store.json` | `dot_config/com.pais.handy/modify_settings_store.json` |

Both are two lines and defer to the shared body in
`.chezmoitemplates/handy-settings.json`. **Edit the shared body, then
`chezmoi apply`.**

To promote a change made in Handy's GUI, read the value out of the live file and
add it to the shared body by hand. Do **not** `chezmoi add` it — that would
capture Handy's runtime state along with it.

#### Gotcha: `template` does not work inside a modify-template

Named templates from `.chezmoitemplates` are not registered in a modify-template's
execution context. This fails with `template "handy-settings.json" not defined`:

```
{{- /* chezmoi:modify-template */ -}}
{{- template "handy-settings.json" . -}}     <-- BROKEN in modify_ files
```

Use `includeTemplate`, which resolves them:

```
{{- /* chezmoi:modify-template */ -}}
{{- includeTemplate "handy-settings.json" . -}}
```

The plain `template` form is fine in ordinary `.tmpl` files (see the VS Code and
tmux configs) — the restriction applies only to `modify_`.

### Linux notes

Text insertion works by synthesising key events, which X11 allows freely and
Wayland gates. Handy ships its own input layer (`keyboard_implementation:
handy_keys`) that drives most compositors via the virtual-keyboard protocol; if a
compositor refuses it, set `typing_tool` to `wtype`/`ydotool`/`kwtype` to match, or
change `paste_method` to `ctrl_shift_v` for terminals that ignore `Ctrl+V`.

The `.deb` needs `libgtk-layer-shell0`; the bootstrap script installs it.

## Add a new file

```bash
chezmoi add ~/.some/config/file
chezmoi git -- add -A
chezmoi git -- commit -m "add some config"
chezmoi git -- push
```
