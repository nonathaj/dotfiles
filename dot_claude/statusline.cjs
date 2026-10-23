#!/usr/bin/env node
// Rich statusline for Claude Code
// When CWD == PRJ: 2 lines (project+git, session info)
// When CWD != PRJ: 3 lines (cwd+git, project+git, session info)
// A 'Limits:' line is appended when a ccburn summary is cached.
//
// PERFORMANCE NOTE (Windows): every process spawn here is scanned by the
// endpoint-security stack (Defender / SentinelOne / Sysmon), so spawns — not
// CPU — are what a status line costs. With dozens of sessions each re-rendering
// on refreshInterval, the bash version (≈15 spawns per render: bash, jq, tr,
// date, stat, timeout, git ×2, subshells) sustained 20+ spawns/s machine-wide.
// This version is ONE node process per render and does everything in-process:
//   * JSON parsing, clock and file-age checks, formatting — no jq/date/stat/tr.
//   * At most ONE git spawn per render (`status --porcelain=v2 --branch`),
//     and none while that directory's cache is fresh. The cache is keyed by
//     directory, so sessions sharing a repo share it (the bash version used one
//     cache slot for all sessions, which thrashed and re-ran git every render).
//   * The remote URL rarely changes, so it is cached for 10 minutes.
//   * ccburn is slow (10–30s per run on a loaded machine), so it runs at most
//     once a minute machine-wide, in a detached background process with a real
//     timeout that kills its whole process tree. The render only reads its cache.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawn } = require('child_process');

const TMP = os.tmpdir();   // same directory Git Bash mounts as /tmp
const CCBURN_CACHE = path.join(TMP, 'claude-statusline-ccburn.json');
const CCBURN_INTERVAL_S = 60;
const CCBURN_TIMEOUT_MS = 60_000;
const GIT_STATUS_MAX_AGE_S = 30;   // ≥ refreshInterval, so idle sessions re-render from cache
const GIT_REMOTE_MAX_AGE_S = 600;
const GIT_TIMEOUT_MS = 5000;

// Models with a native 1M window compact a little before it fills (documented as "about 967K").
const DEFAULT_1M_COMPACT_AT = 967_000;
const ARGV_CACHE_MAX_AGE_S = 7 * 86400;

if (process.argv[2] === '--ccburn-refresh') {
    ccburnRefresh(process.argv[3], process.argv[4]);
} else if (process.argv[2] === '--argv-refresh') {
    argvRefresh(process.argv[3], process.argv[4]);
} else {
    render();
}

function render() {
    let input = '';
    try { input = fs.readFileSync(0, 'utf8'); } catch {}
    if (process.env.STATUSLINE_CAPTURE) {
        try { fs.writeFileSync(process.env.STATUSLINE_CAPTURE, input); } catch {}
    }
    let j = {};
    try { j = JSON.parse(input); } catch {}
    const NOW = Math.floor(Date.now() / 1000);   // one clock read, reused by every freshness check

    maybeRefreshCcburn(input, NOW);

    // ── Colors ──
    const RESET = '\x1b[0m', BOLD = '\x1b[1m', DIM = '\x1b[2m';
    const RED = '\x1b[31m', GREEN = '\x1b[32m', YELLOW = '\x1b[33m', BLUE = '\x1b[34m';
    const MAGENTA = '\x1b[35m', CYAN = '\x1b[36m', WHITE = '\x1b[37m';
    const OSC_OPEN = '\x1b]8;;', OSC_CLOSE = '\x1b]8;;\x07', BEL = '\x07';

    // ── Extract JSON fields ──
    const cw = j.context_window ?? {};
    const cu = cw.current_usage ?? {};
    const pc = j.prompt_cache ?? {};
    const MODEL = j.model?.display_name ?? '';
    const DIR = j.workspace?.project_dir ?? '';
    const CWD = j.workspace?.current_dir ?? '';
    const COST = num(j.cost?.total_cost_usd);
    const PCT = Math.floor(num(cw.used_percentage));
    const CTX_SIZE = num(cw.context_window_size, 200000);
    const CTX_USED = num(cu.input_tokens) + num(cu.cache_creation_input_tokens) + num(cu.cache_read_input_tokens);
    const TOTAL_IN = num(cw.total_input_tokens);
    const TOTAL_OUT = num(cw.total_output_tokens);
    const DURATION_MS = num(j.cost?.total_duration_ms);

    // The session's live effort, so a per-model level from modelSettings or a mid-session /effort shows correctly.
    const EFFORT = j.effort?.level ?? process.env.CLAUDE_EFFORT ?? '';
    const COMPACT_AT = compactThreshold(j, CTX_SIZE);   // tokens; 0 when auto-compact is off

    // ── Format a directory line with git info and column widths ──
    const formatDirLine = (dir, dirW, repo, remote, repoW, branch, branchW, g) => {
        let line = `${BLUE}${BOLD}${dir.padEnd(dirW)}${RESET}`;
        if (repoW > 0) {
            const paddedRepo = repo.padEnd(repoW);
            line += remote
                ? ` ${DIM}│${RESET} ${OSC_OPEN}${remote}${BEL}${CYAN}${paddedRepo}${RESET}${OSC_CLOSE}`
                : ` ${DIM}│${RESET} ${paddedRepo}`;
        }
        if (branchW > 0) {
            line += ` ${DIM}│${RESET} ${MAGENTA}${branch.padEnd(branchW)}${RESET}`;

            // Ahead/behind tracking branch
            let track = '';
            if (g.ahead > 0) track += `${GREEN}↑${g.ahead}${RESET}`;
            if (g.behind > 0) track += `${RED}↓${g.behind}${RESET}`;
            if (track) line += ` ${track}`;

            // Git status indicators
            let status = '';
            if (g.staged > 0) status += ` ${GREEN}+${g.staged}${RESET}`;
            if (g.modified > 0) status += ` ${YELLOW}~${g.modified}${RESET}`;
            if (g.deleted > 0) status += ` ${RED}-${g.deleted}${RESET}`;
            if (g.untracked > 0) status += ` ${DIM}?${g.untracked}${RESET}`;
            line += status || ` ${GREEN}✓${RESET}`;
        }
        return line;
    };

    // ── Build directory lines ──
    let CWD_LINE = '', PRJ_LINE;
    if (CWD !== DIR && CWD) {
        const c = gatherGit(CWD, NOW), p = gatherGit(DIR, NOW);
        const cRepo = repoName(c.remote), pRepo = repoName(p.remote);
        const dirW = Math.max(CWD.length, DIR.length);
        const repoW = Math.max(cRepo.length, pRepo.length);
        const branchW = Math.max(c.branch.length, p.branch.length);
        CWD_LINE = formatDirLine(CWD, dirW, cRepo, c.remote, repoW, c.branch, branchW, c);
        PRJ_LINE = formatDirLine(DIR, dirW, pRepo, p.remote, repoW, p.branch, branchW, p);
    } else {
        // Single line — no padding. Widths are the values' own lengths so repo and
        // branch still show (the bash version passed 0 here, which hid them).
        const g = gatherGit(DIR, NOW);
        const repo = repoName(g.remote);
        PRJ_LINE = formatDirLine(DIR, 0, repo, g.remote, repo.length, g.branch, g.branch.length, g);
    }

    // ── Session line: model | effort | context bar | cost | duration ──
    // The bar spans up to where auto-compact fires (the whole window when it's off),
    // since compaction — not the window — is the real limit. It sits on a solid
    // track, fills to 1/8-cell precision, and shifts green → yellow → red as it fills.
    const fg = n => `\x1b[38;5;${n}m`, bg = n => `\x1b[48;5;${n}m`;
    const BAR_WIDTH = 20;
    const EIGHTHS = ' ▏▎▍▌▋▊▉█';
    const TRACK = bg(238);
    const USED = CTX_USED || PCT * CTX_SIZE / 100;   // current_usage is null right after /compact
    const LIMIT = COMPACT_AT || CTX_SIZE;
    const NEARNESS = USED / LIMIT;
    const FILL = NEARNESS >= 0.85 ? 167 : NEARNESS >= 0.6 ? 179 : 108;
    let BAR = TRACK + fg(FILL);
    for (let i = 0; i < BAR_WIDTH; i++) {
        BAR += EIGHTHS[Math.round(Math.min(Math.max(NEARNESS * BAR_WIDTH - i, 0), 1) * 8)];
    }
    BAR += RESET;

    const COST_FMT = '$' + COST.toFixed(2);

    const TOTAL_SECS = Math.trunc(DURATION_MS / 1000);
    const HOURS = Math.trunc(TOTAL_SECS / 3600);
    const MINS = Math.trunc((TOTAL_SECS % 3600) / 60);
    const SECS = TOTAL_SECS % 60;
    const DURATION_FMT = HOURS > 0 ? `${HOURS}h ${MINS}m ${SECS}s` : MINS > 0 ? `${MINS}m ${SECS}s` : `${SECS}s`;

    const EFFORT_DISPLAY = {
        low: `${DIM}○ lo${RESET}`,
        medium: `${WHITE}◐ med${RESET}`,
        high: `${BOLD}${YELLOW}● hi${RESET}`,
        xhigh: `${BOLD}${YELLOW}◉ xhi${RESET}`,
        max: `${BOLD}${RED}◉ max${RESET}`,
    }[EFFORT] ?? EFFORT;

    let SESSION_LINE = `${CYAN}${MODEL}${RESET}`;
    if (EFFORT_DISPLAY) SESSION_LINE += ` ${EFFORT_DISPLAY}`;
    SESSION_LINE += ` ${DIM}│${RESET} ${BAR} ${Math.floor(NEARNESS * 100)}% ${DIM}${fmtTokens(USED)}/${fmtTokens(LIMIT)}${RESET}`;
    SESSION_LINE += ` ${DIM}│${RESET} ${YELLOW}${COST_FMT}${RESET} ${DIM}↑${fmtTokens(TOTAL_IN)} ↓${fmtTokens(TOTAL_OUT)}${RESET}`;
    SESSION_LINE += ` ${DIM}│${RESET} ${DIM}${DURATION_FMT}${RESET}`;

    // ── Prompt cache: TTL countdown, expiry clock time, hit ratio, misses ──
    // Compared against NOW rather than trusting `warm`, since `warm` is only as fresh
    // as the last event. Claude Code also re-renders when expires_at is reached, and
    // refreshInterval in settings.json keeps the countdown ticking while idle.
    if (pc.caching_observed) {
        const expires = num(pc.expires_at);
        const left = expires - NOW;
        let seg;
        if (expires > 0 && left > 0) {
            const ttlSecs = pc.ttl === '1h' ? 3600 : 300;
            const color = left * 5 < ttlSecs ? YELLOW : GREEN;
            const leftFmt = left >= 60 ? `${Math.trunc((left + 59) / 60)}m` : `${left}s`;
            seg = `${color}⚡cache ${leftFmt}${RESET} ${DIM}→ ${clock(expires)}${RESET}`;
        } else {
            seg = `${DIM}❄ cache cold${RESET}`;
            const recache = num(pc.recache_tokens_if_cold);
            if (recache > 0) seg += ` ${YELLOW}+${fmtTokens(recache)}${RESET}`;
        }
        const hit = roundAway(num(pc.hit_ratio, -0.01) * 100);
        if (hit >= 0) seg += ` ${DIM}hit ${hit}%${RESET}`;
        const misses = num(pc.misses);
        if (misses > 0) seg += ` ${RED}✗${misses}${RESET}`;
        SESSION_LINE += ` ${DIM}│${RESET} ${seg}`;
    }

    // ── ccburn usage line — only READS the cache the background refresh writes ──
    let CCBURN_LINE = '';
    try {
        const cb = JSON.parse(fs.readFileSync(CCBURN_CACHE, 'utf8'));
        const icon = s => ({ behind_pace: '🧊', on_pace: '🔥', ahead_of_pace: '🚨' })[s] ?? '·';
        CCBURN_LINE = Object.entries(cb.limits)
            .filter(([, v]) => !(Date.parse(v.resets_at ?? '') <= Date.now()))   // window reset since ccburn ran: its numbers are void
            .map(([key, v]) => `${icon(v.status)} ${key === 'session' ? '5hr' : key} ${roundAway(v.utilization * 100)}% ${DIM}(${fmtReset(v)})${RESET}`)
            .join(` ${DIM}│${RESET} `);
    } catch {}

    // ── Output ──
    let out = CWD_LINE
        ? `${DIM}cwd:${RESET} ${CWD_LINE}\n${DIM}prj:${RESET} ${PRJ_LINE}\n`
        : `${PRJ_LINE}\n`;
    out += `${SESSION_LINE}\n`;
    if (CCBURN_LINE) out += `${DIM}Limits:${RESET} ${CCBURN_LINE}\n`;
    process.stdout.write(out);
}

// ── Helpers ──

function num(v, dflt = 0) {
    const n = Number(v ?? dflt);
    return Number.isFinite(n) ? n : dflt;
}

// jq's `round`: half away from zero (Math.round rounds -0.5 up).
function roundAway(x) {
    return Math.sign(x) * Math.round(Math.abs(x));
}

// 200000 → 200K, 1000000 → 1M
function fmtTokens(n) {
    if (n >= 1_000_000) return `${Math.trunc(n / 1_000_000)}M`;
    if (n >= 1000) return `${Math.trunc(n / 1000)}K`;
    return `${n}`;
}

function clock(epochSecs) {
    const d = new Date(epochSecs * 1000);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

// Time until a ccburn limit resets. Derived from the absolute `resets_at` when
// present, so the countdown stays right even when the cache is minutes old;
// the relative fields (as of the ccburn run) are the fallback.
function fmtReset(v) {
    const untilMs = Date.parse(v.resets_at ?? '') - Date.now();
    if (v.resets_in_minutes != null) {
        const m = Number.isFinite(untilMs) ? Math.floor(untilMs / 60_000) : v.resets_in_minutes;
        if (m > 0) return m >= 60 ? `${Math.floor(m / 60)}h${Math.trunc(m) % 60}m` : `${m}m`;
    }
    if (v.resets_in_hours != null) {
        const h = Number.isFinite(untilMs) ? untilMs / 3_600_000 : v.resets_in_hours;
        if (h > 0) return h >= 24 ? `${Math.floor(h / 24)}d${Math.floor(h - Math.floor(h / 24) * 24)}h` : `${Math.floor(h)}h`;
    }
    return '';
}

// ── Auto-compact threshold ──
// The status line JSON doesn't say where auto-compact fires, so this resolves it
// the way Claude Code does: CLAUDE_CODE_AUTO_COMPACT_WINDOW > the --autocompact
// launch flag > settings files (managed > project local > project > user; within
// one file a modelSettings window beats the top-level one) > the model's default.
// Returns tokens, capped at the context window, or 0 when auto-compact is off.
function compactThreshold(j, ctxSize) {
    if (/^(1|true|yes)$/i.test(process.env.DISABLE_COMPACT ?? '')) return 0;
    const files = settingsFiles(j.workspace?.project_dir);
    if (files.map(s => s.autoCompactEnabled).find(v => typeof v === 'boolean') === false) return 0;

    const dflt = ctxSize >= 1_000_000 ? DEFAULT_1M_COMPACT_AT : ctxSize;
    const resolve = () => {
        const env = parseWindow(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, false);
        if (env) return env;
        const flag = launchAutocompactFlag(j.session_id);
        if (flag === 'auto') return dflt;
        if (parseWindow(flag, true)) return parseWindow(flag, true);
        for (const s of files) {
            const w = s.modelSettings?.[j.model?.id]?.autoCompactWindow ?? s.autoCompactWindow;
            if (w === 'auto') return dflt;
            if (parseWindow(w, false)) return parseWindow(w, false);
        }
        return dflt;
    };
    return Math.min(resolve(), ctxSize);
}

// A window size as Claude Code reads it: a token count, or with a k/M suffix.
// The launch flag also reads a bare 100–1000 as thousands. Clamped to 100K–1M;
// anything else is 0 (unset).
function parseWindow(v, bareThousands) {
    const m = /^\s*(\d+(?:\.\d+)?)\s*([km]?)\s*$/i.exec(String(v ?? ''));
    if (!m) return 0;
    let n = Number(m[1]) * ({ k: 1e3, m: 1e6 }[m[2].toLowerCase()] ?? 1);
    if (!m[2] && bareThousands && n >= 100 && n <= 1000) n *= 1000;
    return Math.min(Math.max(Math.round(n), 100_000), 1_000_000);
}

// Parsed settings files, highest precedence first. Missing or broken files are skipped.
function settingsFiles(projectDir) {
    const managed = {
        win32: 'C:\\Program Files\\ClaudeCode\\managed-settings.json',
        darwin: '/Library/Application Support/ClaudeCode/managed-settings.json',
    }[process.platform] ?? '/etc/claude-code/managed-settings.json';
    const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
    const paths = [managed];
    if (projectDir) paths.push(path.join(projectDir, '.claude', 'settings.local.json'), path.join(projectDir, '.claude', 'settings.json'));
    paths.push(path.join(configDir, 'settings.json'));
    return paths.flatMap(p => { try { return [JSON.parse(fs.readFileSync(p, 'utf8'))]; } catch { return []; } });
}

// The value of the --autocompact flag Claude Code was launched with ('auto', a
// size, or undefined). Only the process command line has it, and reading that
// costs a ~1.5s CIM query on Windows, so a detached refresh does it once per
// Claude process and session (the key guards against PID reuse) and the render
// only reads the cache.
function launchAutocompactFlag(sessionId) {
    const pid = Number(process.env.CLAUDE_PID);
    if (!pid || !sessionId) return undefined;
    const cacheFile = path.join(TMP, `claude-statusline-argv-${pid}-${sessionId}.json`);
    try { return JSON.parse(fs.readFileSync(cacheFile, 'utf8')).autocompact ?? undefined; } catch {}
    const mark = cacheFile + '.mark';
    if (fs.existsSync(mark)) return undefined;   // refresh pending, or it failed and won't be retried
    try {
        fs.writeFileSync(mark, '');
        spawn(process.execPath, [__filename, '--argv-refresh', String(pid), cacheFile], {
            detached: true, stdio: 'ignore', windowsHide: true,
        }).unref();
    } catch {}
    return undefined;
}

function argvRefresh(pid, cacheFile) {
    const opts = { encoding: 'utf8', timeout: 30_000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] };
    let cmd;
    try {
        cmd = process.platform === 'win32'
            ? execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command',
                `(Get-CimInstance Win32_Process -Filter 'ProcessId=${Number(pid)}').CommandLine`], opts)
            : execFileSync('ps', ['-o', 'args=', '-p', String(Number(pid))], opts);
    } catch { return; }
    let autocompact = null;
    for (const m of cmd.matchAll(/--autocompact(?:=|\s+)"?([^\s"]+)/g)) autocompact = m[1];   // the last one wins
    try {
        const tmp = `${cacheFile}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify({ autocompact }));
        fs.renameSync(tmp, cacheFile);
    } catch {}

    // Sweep caches of long-gone sessions.
    const cutoff = Date.now() - ARGV_CACHE_MAX_AGE_S * 1000;
    try {
        for (const f of fs.readdirSync(TMP)) {
            if (!f.startsWith('claude-statusline-argv-')) continue;
            const p = path.join(TMP, f);
            try { if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p); } catch {}
        }
    } catch {}
}

// org/repo from a remote URL
function repoName(remote) {
    if (!remote) return '';
    const u = remote.replace(/\/$/, '');
    const head = u.includes('/') ? u.slice(0, u.lastIndexOf('/')) : u;
    return `${head.slice(head.lastIndexOf('/') + 1)}/${u.slice(u.lastIndexOf('/') + 1)}`;
}

function git(dir, args) {
    return execFileSync('git', ['-C', dir, ...args], {
        encoding: 'utf8', timeout: GIT_TIMEOUT_MS, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'],
    });
}

// Git branch/ahead/behind/status/remote for a directory, cached per directory
// in TMP so every session looking at the same repo shares one git call.
function gatherGit(dir, NOW) {
    const empty = { branch: '', ahead: 0, behind: 0, staged: 0, modified: 0, deleted: 0, untracked: 0, remote: '' };
    const key = require('crypto').createHash('sha1').update(dir).digest('hex').slice(0, 16);
    const cacheFile = path.join(TMP, `claude-statusline-git-${key}.json`);
    let c = null;
    try { c = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); } catch {}
    if (c?.dir !== dir) c = null;
    if (c && NOW - c.statusAt <= GIT_STATUS_MAX_AGE_S) return c.data;

    let data;
    try {
        // One git call for branch, ahead/behind AND all file states.
        const out = git(dir, ['status', '--porcelain=v2', '--branch']).replace(/\r/g, '');
        data = { ...empty };
        for (const line of out.split('\n')) {
            if (line.startsWith('# branch.head ')) data.branch = line.slice(14);
            else if (line.startsWith('# branch.ab ')) {
                const [a, b] = line.slice(12).split(' ');
                data.ahead = Number(a.replace('+', '')) || 0;
                data.behind = Number(b.replace('-', '')) || 0;
            } else if (line.startsWith('1 ') || line.startsWith('2 ')) {
                const xy = line.slice(2, 4);
                if (xy[0] !== '.') data.staged++;
                if (xy[1] === 'M') data.modified++;
                if (xy[1] === 'D') data.deleted++;
            } else if (line.startsWith('? ')) data.untracked++;
        }
        if (data.branch === '(detached)') data.branch = '';

        let remoteAt = c?.remoteAt ?? 0;
        data.remote = c?.data.remote ?? '';
        if (NOW - remoteAt > GIT_REMOTE_MAX_AGE_S) {
            try {
                data.remote = git(dir, ['remote', 'get-url', 'origin']).trim()
                    .replace('git@github.com:', 'https://github.com/').replace(/\.git$/, '');
                remoteAt = NOW;
            } catch (e) {
                if (e.code !== 'ETIMEDOUT') { data.remote = ''; remoteAt = NOW; }   // no origin
            }
        }
        c = { dir, statusAt: NOW, remoteAt, data };
    } catch (e) {
        // Timed out: keep showing the last known state rather than blanking it.
        // Otherwise it's not a repo. Either way, stamp statusAt so a slow or
        // failing git isn't re-run on every render.
        data = e.code === 'ETIMEDOUT' && c ? c.data : empty;
        c = { dir, statusAt: NOW, remoteAt: c?.remoteAt ?? 0, data };
    }
    try { fs.writeFileSync(cacheFile, JSON.stringify(c)); } catch {}
    return data;
}

// ── ccburn (optional) ──
// ccburn keeps a local SQLite DB warm from the statusline JSON (`collect`) and
// produces a usage summary (`--once --json`). Both are slow, so a detached
// background process does them at most once per CCBURN_INTERVAL_S machine-wide
// (the mark is stamped on LAUNCH, so a slow or hung run can't retry-storm).
function maybeRefreshCcburn(input, NOW) {
    const mark = CCBURN_CACHE + '.mark';
    try { if (NOW - Math.floor(fs.statSync(mark).mtimeMs / 1000) < CCBURN_INTERVAL_S) return; } catch {}
    const exe = findOnPath('ccburn');
    if (!exe) return;
    try {
        fs.writeFileSync(mark, '');
        const inputFile = path.join(TMP, `claude-statusline-ccburn-input-${process.pid}.json`);
        fs.writeFileSync(inputFile, input);
        spawn(process.execPath, [__filename, '--ccburn-refresh', exe, inputFile], {
            detached: true, stdio: 'ignore', windowsHide: true,
        }).unref();
    } catch {}
}

async function ccburnRefresh(exe, inputFile) {
    let input = '';
    try { input = fs.readFileSync(inputFile); fs.unlinkSync(inputFile); } catch {}
    await run(exe, ['collect'], input);
    const json = await run(exe, ['--once', '--json'], null);
    try {
        JSON.parse(json);   // only replace the cache with a complete, valid summary
        const tmp = `${CCBURN_CACHE}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, json);
        fs.renameSync(tmp, CCBURN_CACHE);
    } catch {}
}

// Run a command with a timeout that kills its whole process tree (a plain
// kill only reaches the direct child, which leaks a launcher's children).
function run(exe, args, input) {
    return new Promise(resolve => {
        const child = spawn(exe, args, { windowsHide: true, stdio: [input == null ? 'ignore' : 'pipe', 'pipe', 'ignore'] });
        let out = '';
        child.stdout.on('data', d => { out += d; });
        const timer = setTimeout(() => {
            try { execFileSync('taskkill', ['/T', '/F', '/PID', String(child.pid)], { stdio: 'ignore', windowsHide: true }); } catch {}
        }, CCBURN_TIMEOUT_MS);
        child.on('error', () => { clearTimeout(timer); resolve(''); });
        child.on('close', code => { clearTimeout(timer); resolve(code === 0 ? out : ''); });
        if (input != null) child.stdin.end(input);
    });
}

function findOnPath(name) {
    const exts = process.platform === 'win32' ? ['.exe', ''] : [''];
    for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
        for (const ext of exts) {
            const p = path.join(dir, name + ext);
            try { if (fs.statSync(p).isFile()) return p; } catch {}
        }
    }
    return null;
}
