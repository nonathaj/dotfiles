#!/usr/bin/env bash
# Rich statusline for Claude Code
# When CWD == PRJ: 2 lines (project+git, session info)
# When CWD != PRJ: 3 lines (cwd+git, project+git, session info)
#
# PERFORMANCE NOTE (Windows / Git Bash): process creation here is dominated by
# Windows Defender scanning each spawn (~0.3-0.5s) AND msys emulating fork() for
# every `$(...)` command substitution (~0.1-0.2s). A status line that spawns a
# few dozen processes therefore takes >10s and Claude Code cancels it on the
# next event, so it never appears. This script is written to minimise spawns:
#   * ONE jq call parses every field (not a dozen).
#   * ONE git call per repo gathers branch+ahead/behind+status (not ~8).
#   * Helper functions set globals instead of echo|$() (no fork per call).
#   * File reads use bash builtins ($(<f), read) instead of cat.
#   * ccburn runs at most once per 12s, fully backgrounded.

IFS= read -rd '' input || true   # slurp stdin without spawning `cat`
NOW=$(date +%s)                  # one clock read, reused by every freshness check below

# ── ccburn (optional) — throttled + fully backgrounded ──
# ccburn keeps a local SQLite DB warm from the statusline JSON (no API call) and
# produces a usage summary. Previously a `collect` ran every render AND a
# synchronous `--once --json` (up to 3s, frequently timing out) ran on the
# critical path. On a busy agent that starved the status line so it never
# finished before Claude Code cancelled it. Now ccburn runs AT MOST once per
# 12s, entirely in the background, writing a display cache the render reads
# instantly — it can never block or delay the status line.
# NB: on Windows, msys `timeout` cannot kill a native ccburn.exe that hangs, so
# a stuck ccburn leaks a process. Throttling bounds how fast those can pile up.
CCBURN_CACHE="/tmp/claude-statusline-ccburn.json"
if command -v ccburn >/dev/null 2>&1; then
    _cb_age=999
    [ -f "${CCBURN_CACHE}.mark" ] && _cb_age=$(( NOW - $(stat -c %Y "${CCBURN_CACHE}.mark" 2>/dev/null || stat -f %m "${CCBURN_CACHE}.mark" 2>/dev/null || echo 0) ))
    if [ "$_cb_age" -ge 12 ]; then
        : > "${CCBURN_CACHE}.mark"   # stamp on LAUNCH (not success) so a hung ccburn can't retry-storm
        (
            printf '%s' "$input" | ccburn collect >/dev/null 2>&1
            timeout 6 ccburn --once --json > "${CCBURN_CACHE}.tmp" 2>/dev/null \
                && mv -f "${CCBURN_CACHE}.tmp" "$CCBURN_CACHE" 2>/dev/null \
                || rm -f "${CCBURN_CACHE}.tmp" 2>/dev/null
        ) &
        disown 2>/dev/null
    fi
fi

# ── Colors (use $'...' so escapes are expanded at assignment) ──
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'
OSC_OPEN=$'\033]8;;'
OSC_CLOSE=$'\033]8;;\a'
BEL=$'\a'

# ── Extract JSON fields (single jq call — one process spawn, not a dozen) ──
# We emit ONE FIELD PER LINE — NOT @tsv, which would JSON-escape the backslashes
# in Windows paths (D:\dev -> D:\\dev). With one value per line, `jq -r` keeps
# backslashes raw. `tr -d '\r'` strips the CR that native-Windows jq.exe appends
# to each line; mapfile/read don't strip it the way $() does, which would
# otherwise corrupt fields and break the numeric/arithmetic handling downstream.
mapfile -t _F < <(
    printf '%s' "$input" | jq -r '
        .model.display_name // "",
        .model.id // "",
        .workspace.project_dir // "",
        .workspace.current_dir // "",
        (.cost.total_cost_usd // 0),
        ((.context_window.used_percentage // 0) | floor),
        (.context_window.context_window_size // 200000),
        ((.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))),
        (.context_window.total_input_tokens // 0),
        (.context_window.total_output_tokens // 0),
        (.cost.total_duration_ms // 0)
    ' | tr -d '\r'
)
MODEL=${_F[0]}; MODEL_ID=${_F[1]}; DIR=${_F[2]}; CWD=${_F[3]}
COST=${_F[4]}; PCT=${_F[5]}; CTX_SIZE=${_F[6]}; CTX_USED=${_F[7]}
TOTAL_IN=${_F[8]}; TOTAL_OUT=${_F[9]}; DURATION_MS=${_F[10]}

# ── Effort level (read from settings, not in statusline JSON) ──
# bash builtin read ($(<f)) + regex — avoids a jq process spawn.
EFFORT=""
if [ -f "$HOME/.claude/settings.json" ]; then
    _settings=$(<"$HOME/.claude/settings.json")
    [[ $_settings =~ \"effortLevel\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && EFFORT="${BASH_REMATCH[1]}"
fi

# ── Format token counts (200000 → 200K, 1000000 → 1M) ──
# Sets FMT_OUT (no echo/$()) so callers don't fork a subshell — expensive on msys.
fmt_tokens() {
    local n=$1
    if   [ "$n" -ge 1000000 ] 2>/dev/null; then FMT_OUT="$((n / 1000000))M"
    elif [ "$n" -ge 1000 ]    2>/dev/null; then FMT_OUT="$((n / 1000))K"
    else FMT_OUT="$n"; fi
}
fmt_tokens "$CTX_SIZE"; CTX_LABEL=$FMT_OUT
fmt_tokens "$CTX_USED"; CTX_USED_LABEL=$FMT_OUT

# ── Git info gathering (cached per directory) ──
CACHE_MAX_AGE=5

# Gather git info for a directory, using a named cache.
# Cache file format: line 1 = dir it was gathered for, line 2 = pipe-delimited data.
# Usage: gather_git <directory> <cache_suffix>
# Sets: G_BRANCH G_STAGED G_MODIFIED G_DELETED G_UNTRACKED G_AHEAD G_BEHIND G_REMOTE
gather_git() {
    local target_dir=$1 suffix=$2
    local cache="/tmp/claude-statusline-git-cache-${suffix}"
    local cached_dir="" cached_data=""
    if [ -f "$cache" ]; then
        { IFS= read -r cached_dir; IFS= read -r cached_data; } < "$cache" 2>/dev/null
    fi

    local stale=0
    if [ ! -f "$cache" ] || [ "$cached_dir" != "$target_dir" ] || \
       [ $((NOW - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]; then
        stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        local status_out branch="" ahead=0 behind=0 staged=0 modified=0 deleted=0 untracked=0 remote=""
        if status_out=$(timeout 3 git -C "$target_dir" status --porcelain=v2 --branch 2>/dev/null); then
            # Parse branch, ahead/behind AND all file states from ONE git call
            # (was ~8). On Windows each git spawn is ~0.3-0.5s, so the worktree
            # case (cwd!=prj => two repos => ~16 spawns => >10s) is what blew
            # past Claude Code's render window and made the status line vanish.
            status_out="${status_out//$'\r'/}"   # native git may emit CRLF
            local line xy ab
            while IFS= read -r line; do
                case "$line" in
                    "# branch.head "*) branch="${line#\# branch.head }" ;;
                    "# branch.ab "*)
                        ab="${line#\# branch.ab }"
                        ahead="${ab%% *}"; ahead="${ahead#+}"
                        behind="${ab##* }"; behind="${behind#-}"
                        ;;
                    "1 "*|"2 "*)
                        xy="${line:2:2}"
                        [ "${xy:0:1}" != "." ] && staged=$((staged+1))
                        [ "${xy:1:1}" = "M" ] && modified=$((modified+1))
                        [ "${xy:1:1}" = "D" ] && deleted=$((deleted+1))
                        ;;
                    "? "*) untracked=$((untracked+1)) ;;
                esac
            done <<< "$status_out"
            [ "$branch" = "(detached)" ] && branch=""
            remote=$(git -C "$target_dir" remote get-url origin 2>/dev/null)
            remote="${remote/git@github.com:/https://github.com/}"; remote="${remote%.git}"
            cached_data="${branch}|${staged}|${modified}|${deleted}|${untracked}|${ahead}|${behind}|${remote}"
        else
            cached_data="|||||||"
        fi
        printf '%s\n%s\n' "$target_dir" "$cached_data" > "$cache"
    fi

    IFS='|' read -r G_BRANCH G_STAGED G_MODIFIED G_DELETED G_UNTRACKED G_AHEAD G_BEHIND G_REMOTE <<< "$cached_data"
}

# Helper: pad a string to a given visible width. Sets PAD_OUT (no echo/$()).
pad() {
    local str=$1 width=$2 len=${#1}
    if [ "$width" -gt "$len" ]; then
        local p; printf -v p "%$((width - len))s" ""
        PAD_OUT="${str}${p}"
    else
        PAD_OUT="$str"
    fi
}

# Extract repo name (org/repo) from a remote URL. Sets REPO_NAME (no sed/$()).
repo_name_from_remote() {
    local u=${1%/}
    local head=${u%/*}
    REPO_NAME="${head##*/}/${u##*/}"
}

# Format a directory line with git info and column widths. Sets FMT_DIR_LINE.
# Usage: format_dir_line <dir> <dir_w> <repo> <remote> <repo_w> <branch> <branch_w> <ahead> <behind> <staged> <modified> <deleted> <untracked>
format_dir_line() {
    local dir_path=$1 dir_w=$2
    local repo=$3 remote=$4 repo_w=$5
    local branch=$6 branch_w=$7
    local ahead=$8 behind=$9 staged=${10} modified=${11} deleted=${12} untracked=${13}

    # Padded directory
    pad "$dir_path" "$dir_w"; local padded_dir=$PAD_OUT
    local line="${BLUE}${BOLD}${padded_dir}${RESET}"

    # Padded repo (clickable link)
    if [ "$repo_w" -gt 0 ]; then
        pad "$repo" "$repo_w"; local padded_repo=$PAD_OUT
        if [ -n "$remote" ]; then
            line="${line} ${DIM}│${RESET} ${OSC_OPEN}${remote}${BEL}${CYAN}${padded_repo}${RESET}${OSC_CLOSE}"
        else
            line="${line} ${DIM}│${RESET} ${padded_repo}"
        fi
    fi

    # Padded branch + ahead/behind + status
    if [ "$branch_w" -gt 0 ]; then
        pad "$branch" "$branch_w"; local padded_branch=$PAD_OUT
        line="${line} ${DIM}│${RESET} ${MAGENTA}${padded_branch}${RESET}"

        # Ahead/behind tracking branch
        local track=""
        [ "$ahead" -gt 0 ] 2>/dev/null && track="${track}${GREEN}↑${ahead}${RESET}"
        [ "$behind" -gt 0 ] 2>/dev/null && track="${track}${RED}↓${behind}${RESET}"
        [ -n "$track" ] && line="${line} ${track}"

        # Git status indicators
        local status=""
        [ "$staged" -gt 0 ] 2>/dev/null && status="${status} ${GREEN}+${staged}${RESET}"
        [ "$modified" -gt 0 ] 2>/dev/null && status="${status} ${YELLOW}~${modified}${RESET}"
        [ "$deleted" -gt 0 ] 2>/dev/null && status="${status} ${RED}-${deleted}${RESET}"
        [ "$untracked" -gt 0 ] 2>/dev/null && status="${status} ${DIM}?${untracked}${RESET}"

        if [ -z "$status" ]; then
            line="${line} ${GREEN}✓${RESET}"
        else
            line="${line}${status}"
        fi
    fi

    FMT_DIR_LINE="$line"
}

# ── Build directory lines ──
CWD_LINE=""
if [ "$CWD" != "$DIR" ] && [ -n "$CWD" ]; then
    # Gather git data for both directories
    gather_git "$CWD" "cwd"
    CWD_BRANCH=$G_BRANCH; CWD_STAGED=$G_STAGED; CWD_MODIFIED=$G_MODIFIED
    CWD_DELETED=$G_DELETED; CWD_UNTRACKED=$G_UNTRACKED
    CWD_AHEAD=$G_AHEAD; CWD_BEHIND=$G_BEHIND; CWD_REMOTE=$G_REMOTE
    CWD_REPO=""; [ -n "$CWD_REMOTE" ] && { repo_name_from_remote "$CWD_REMOTE"; CWD_REPO=$REPO_NAME; }

    gather_git "$DIR" "prj"
    PRJ_BRANCH=$G_BRANCH; PRJ_STAGED=$G_STAGED; PRJ_MODIFIED=$G_MODIFIED
    PRJ_DELETED=$G_DELETED; PRJ_UNTRACKED=$G_UNTRACKED
    PRJ_AHEAD=$G_AHEAD; PRJ_BEHIND=$G_BEHIND; PRJ_REMOTE=$G_REMOTE
    PRJ_REPO=""; [ -n "$PRJ_REMOTE" ] && { repo_name_from_remote "$PRJ_REMOTE"; PRJ_REPO=$REPO_NAME; }

    # Compute column widths (max of both rows) — inlined, no subshell fork
    DIR_W=${#CWD};           [ ${#DIR} -gt "$DIR_W" ]           && DIR_W=${#DIR}
    REPO_W=${#CWD_REPO};     [ ${#PRJ_REPO} -gt "$REPO_W" ]     && REPO_W=${#PRJ_REPO}
    BRANCH_W=${#CWD_BRANCH}; [ ${#PRJ_BRANCH} -gt "$BRANCH_W" ] && BRANCH_W=${#PRJ_BRANCH}

    format_dir_line "$CWD" "$DIR_W" "$CWD_REPO" "$CWD_REMOTE" "$REPO_W" "$CWD_BRANCH" "$BRANCH_W" "$CWD_AHEAD" "$CWD_BEHIND" "$CWD_STAGED" "$CWD_MODIFIED" "$CWD_DELETED" "$CWD_UNTRACKED"; CWD_LINE=$FMT_DIR_LINE
    format_dir_line "$DIR" "$DIR_W" "$PRJ_REPO" "$PRJ_REMOTE" "$REPO_W" "$PRJ_BRANCH" "$BRANCH_W" "$PRJ_AHEAD" "$PRJ_BEHIND" "$PRJ_STAGED" "$PRJ_MODIFIED" "$PRJ_DELETED" "$PRJ_UNTRACKED"; PRJ_LINE=$FMT_DIR_LINE
else
    # Single line — no padding needed
    gather_git "$DIR" "prj"
    PRJ_REPO=""; [ -n "$G_REMOTE" ] && { repo_name_from_remote "$G_REMOTE"; PRJ_REPO=$REPO_NAME; }
    format_dir_line "$DIR" "0" "$PRJ_REPO" "$G_REMOTE" "0" "$G_BRANCH" "0" "$G_AHEAD" "$G_BEHIND" "$G_STAGED" "$G_MODIFIED" "$G_DELETED" "$G_UNTRACKED"; PRJ_LINE=$FMT_DIR_LINE
fi

# ── Build session line: model | effort | context bar | cost | duration ──

# Context bar with threshold colors
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

BAR_WIDTH=15
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
if [ "$FILLED" -gt 0 ]; then
    printf -v FILL "%${FILLED}s"
    BAR="${FILL// /█}"
fi
if [ "$EMPTY" -gt 0 ]; then
    printf -v PADBAR "%${EMPTY}s"
    BAR="${BAR}${PADBAR// /░}"
fi

# Cost (printf -v — builtin, no subshell fork)
printf -v COST_FMT '$%.2f' "$COST" 2>/dev/null

# Duration
TOTAL_SECS=$((DURATION_MS / 1000))
HOURS=$((TOTAL_SECS / 3600))
MINS=$(((TOTAL_SECS % 3600) / 60))
SECS=$((TOTAL_SECS % 60))
if [ "$HOURS" -gt 0 ]; then
    DURATION_FMT="${HOURS}h ${MINS}m ${SECS}s"
elif [ "$MINS" -gt 0 ]; then
    DURATION_FMT="${MINS}m ${SECS}s"
else
    DURATION_FMT="${SECS}s"
fi

# Effort
EFFORT_DISPLAY=""
if [ -n "$EFFORT" ]; then
    case "$EFFORT" in
        low)    EFFORT_DISPLAY="${DIM}○ lo${RESET}" ;;
        medium) EFFORT_DISPLAY="${WHITE}◐ med${RESET}" ;;
        high)   EFFORT_DISPLAY="${BOLD}${YELLOW}● hi${RESET}" ;;
        max)    EFFORT_DISPLAY="${BOLD}${YELLOW}◉ max${RESET}" ;;
        *)      EFFORT_DISPLAY="${EFFORT}" ;;
    esac
fi

SESSION_LINE="${CYAN}${MODEL}${RESET}"
[ -n "$EFFORT_DISPLAY" ] && SESSION_LINE="${SESSION_LINE} ${EFFORT_DISPLAY}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${BAR_COLOR}${BAR}${RESET} ${PCT}% ${DIM}${CTX_USED_LABEL}/${CTX_LABEL}${RESET}"
fmt_tokens "$TOTAL_IN";  IN_LABEL=$FMT_OUT
fmt_tokens "$TOTAL_OUT"; OUT_LABEL=$FMT_OUT
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${YELLOW}${COST_FMT}${RESET} ${DIM}↑${IN_LABEL} ↓${OUT_LABEL}${RESET}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${DIM}${DURATION_FMT}${RESET}"

# ── ccburn display line (optional) ──
# Render a single-line usage summary as the bottom row. We use --json (not
# --compact) and format ourselves so we get real pace emojis and styling
# consistent with the rest of the statusline. The compact mode only emits ASCII
# brackets and additionally mis-encodes its separator as CP1252 on Windows.
# This block only READS the cache written by the throttled background job at the
# TOP of this script — it never spawns ccburn, so it adds no latency.
CCBURN_LINE=""
CCBURN_JSON=""
[ -n "$CCBURN_CACHE" ] && [ -f "$CCBURN_CACHE" ] && CCBURN_JSON=$(<"$CCBURN_CACHE")
if [ -n "$CCBURN_JSON" ]; then
        CCBURN_LINE=$(echo "$CCBURN_JSON" | jq -r \
            --arg sep " ${DIM}│${RESET} " \
            --arg dim "$DIM" \
            --arg reset "$RESET" '
            def icon:
                if . == "behind_pace" then "🧊"
                elif . == "on_pace" then "🔥"
                elif . == "ahead_of_pace" then "🚨"
                else "·" end;
            def fmt_reset:
                if .resets_in_minutes != null and .resets_in_minutes > 0 then
                    (if .resets_in_minutes >= 60
                        then ((.resets_in_minutes / 60 | floor) | tostring) + "h" + ((.resets_in_minutes % 60) | tostring) + "m"
                        else (.resets_in_minutes | tostring) + "m" end)
                elif .resets_in_hours != null and .resets_in_hours > 0 then
                    (if .resets_in_hours >= 24
                        then ((.resets_in_hours / 24 | floor) | tostring) + "d" + ((.resets_in_hours - (.resets_in_hours / 24 | floor) * 24) | floor | tostring) + "h"
                        else (.resets_in_hours | floor | tostring) + "h" end)
                else "" end;
            [.limits | to_entries[] |
                "\(.value.status | icon) \(.key) \((.value.utilization * 100) | round)% \($dim)(\(.value | fmt_reset))\($reset)"
            ] | join($sep)
        ' 2>/dev/null)
fi

# ── Output ──
if [ -n "$CWD_LINE" ]; then
    printf '%s\n' "${DIM}cwd:${RESET} $CWD_LINE"
    printf '%s\n' "${DIM}prj:${RESET} $PRJ_LINE"
else
    printf '%s\n' "$PRJ_LINE"
fi
printf '%s\n' "$SESSION_LINE"
[ -n "$CCBURN_LINE" ] && printf '%s\n' "$CCBURN_LINE"

# Always exit 0: the `&&` above returns non-zero when there is no ccburn line,
# and Claude Code blanks the status line on any non-zero exit.
exit 0
