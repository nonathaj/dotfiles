#!/usr/bin/env bash
# Rich statusline for Claude Code
# When CWD == PRJ: 2 lines (project+git, session info)
# When CWD != PRJ: 3 lines (cwd+git, project+git, session info)

input=$(cat)

# ── ccburn collect (optional) ──
# If ccburn is installed, feed it a copy of the statusline JSON so its local
# SQLite DB stays warm with rate_limits data (avoids OAuth API rate limits when
# ccburn is run interactively). Fire-and-forget; stdout (passthrough) is
# discarded since we already consumed stdin ourselves.
if command -v ccburn >/dev/null 2>&1; then
    (printf '%s' "$input" | ccburn collect >/dev/null 2>&1) &
    disown 2>/dev/null
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

# ── Extract JSON fields ──
MODEL=$(echo "$input" | jq -r '.model.display_name')
MODEL_ID=$(echo "$input" | jq -r '.model.id')
DIR=$(echo "$input" | jq -r '.workspace.project_dir')
CWD=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
CTX_USED=$(echo "$input" | jq -r '(.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))')
TOTAL_IN=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOTAL_OUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# ── Effort level (read from settings, not in statusline JSON) ──
EFFORT=""
if [ -f "$HOME/.claude/settings.json" ]; then
    EFFORT=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
fi

# ── Format token counts (200000 → 200K, 1000000 → 1M) ──
fmt_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
        echo "$((n / 1000000))M"
    elif [ "$n" -ge 1000 ]; then
        echo "$((n / 1000))K"
    else
        echo "$n"
    fi
}
CTX_LABEL=$(fmt_tokens "$CTX_SIZE")
CTX_USED_LABEL=$(fmt_tokens "$CTX_USED")

# ── Git info gathering (cached per directory) ──
CACHE_MAX_AGE=5

# Gather git info for a directory, using a named cache
# Usage: gather_git <directory> <cache_suffix>
# Sets: G_BRANCH G_STAGED G_MODIFIED G_DELETED G_UNTRACKED G_AHEAD G_BEHIND G_REMOTE
gather_git() {
    local target_dir=$1
    local suffix=$2
    local cache="/tmp/claude-statusline-git-cache-${suffix}"
    local cache_dir="/tmp/claude-statusline-git-cache-${suffix}-dir"

    local stale=0
    if [ ! -f "$cache" ] || [ ! -f "$cache_dir" ] || \
       [ "$(cat "$cache_dir" 2>/dev/null)" != "$target_dir" ] || \
       [ $(($(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]; then
        stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        if timeout 2 git -C "$target_dir" rev-parse --git-dir > /dev/null 2>&1; then
            local branch=$(git -C "$target_dir" branch --show-current 2>/dev/null)
            local staged=$(git -C "$target_dir" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
            local modified=$(git -C "$target_dir" diff --diff-filter=M --numstat 2>/dev/null | wc -l | tr -d ' ')
            local deleted=$(git -C "$target_dir" diff --diff-filter=D --numstat 2>/dev/null | wc -l | tr -d ' ')
            local untracked=$(git -C "$target_dir" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
            local ab=$(git -C "$target_dir" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0	0")
            local ahead=$(echo "$ab" | cut -f1)
            local behind=$(echo "$ab" | cut -f2)
            local remote=$(git -C "$target_dir" remote get-url origin 2>/dev/null | sed 's/git@github\.com:/https:\/\/github.com\//' | sed 's/\.git$//')
            echo "${branch}|${staged}|${modified}|${deleted}|${untracked}|${ahead}|${behind}|${remote}" > "$cache"
            echo "$target_dir" > "$cache_dir"
        else
            echo "|||||||" > "$cache"
            echo "$target_dir" > "$cache_dir"
        fi
    fi

    IFS='|' read -r G_BRANCH G_STAGED G_MODIFIED G_DELETED G_UNTRACKED G_AHEAD G_BEHIND G_REMOTE < "$cache"
}

# Helper: pad a string to a given visible width
# Usage: pad <string> <width> → outputs string + spaces
pad() {
    local str=$1 width=$2
    local len=${#str}
    local padding=""
    if [ "$width" -gt "$len" ]; then
        printf -v padding "%$((width - len))s" ""
    fi
    echo "${str}${padding}"
}

# Helper: max of two numbers
max() { [ "$1" -gt "$2" ] && echo "$1" || echo "$2"; }

# Extract repo name from remote URL (org/repo)
repo_name_from_remote() {
    echo "$1" | sed 's|.*/\([^/]*/[^/]*\)$|\1|'
}

# Format a directory line with git info and column widths
# Usage: format_dir_line <dir> <dir_w> <repo> <remote> <repo_w> <branch> <branch_w> <ahead> <behind> <staged> <modified> <deleted> <untracked>
format_dir_line() {
    local dir_path=$1 dir_w=$2
    local repo=$3 remote=$4 repo_w=$5
    local branch=$6 branch_w=$7
    local ahead=$8 behind=$9 staged=${10} modified=${11} deleted=${12} untracked=${13}

    # Padded directory
    local padded_dir=$(pad "$dir_path" "$dir_w")
    local line="${BLUE}${BOLD}${padded_dir}${RESET}"

    # Padded repo (clickable link)
    if [ "$repo_w" -gt 0 ]; then
        local padded_repo=$(pad "$repo" "$repo_w")
        if [ -n "$remote" ]; then
            line="${line} ${DIM}│${RESET} ${OSC_OPEN}${remote}${BEL}${CYAN}${padded_repo}${RESET}${OSC_CLOSE}"
        else
            line="${line} ${DIM}│${RESET} ${padded_repo}"
        fi
    fi

    # Padded branch + ahead/behind + status
    if [ "$branch_w" -gt 0 ]; then
        local padded_branch=$(pad "$branch" "$branch_w")
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

    echo "$line"
}

# ── Build directory lines ──
CWD_LINE=""
if [ "$CWD" != "$DIR" ] && [ -n "$CWD" ]; then
    # Gather git data for both directories
    gather_git "$CWD" "cwd"
    CWD_BRANCH=$G_BRANCH; CWD_STAGED=$G_STAGED; CWD_MODIFIED=$G_MODIFIED
    CWD_DELETED=$G_DELETED; CWD_UNTRACKED=$G_UNTRACKED
    CWD_AHEAD=$G_AHEAD; CWD_BEHIND=$G_BEHIND; CWD_REMOTE=$G_REMOTE
    CWD_REPO=""; [ -n "$CWD_REMOTE" ] && CWD_REPO=$(repo_name_from_remote "$CWD_REMOTE")

    gather_git "$DIR" "prj"
    PRJ_BRANCH=$G_BRANCH; PRJ_STAGED=$G_STAGED; PRJ_MODIFIED=$G_MODIFIED
    PRJ_DELETED=$G_DELETED; PRJ_UNTRACKED=$G_UNTRACKED
    PRJ_AHEAD=$G_AHEAD; PRJ_BEHIND=$G_BEHIND; PRJ_REMOTE=$G_REMOTE
    PRJ_REPO=""; [ -n "$PRJ_REMOTE" ] && PRJ_REPO=$(repo_name_from_remote "$PRJ_REMOTE")

    # Compute column widths (max of both rows)
    DIR_W=$(max ${#CWD} ${#DIR})
    REPO_W=$(max ${#CWD_REPO} ${#PRJ_REPO})
    BRANCH_W=$(max ${#CWD_BRANCH} ${#PRJ_BRANCH})

    CWD_LINE=$(format_dir_line "$CWD" "$DIR_W" "$CWD_REPO" "$CWD_REMOTE" "$REPO_W" "$CWD_BRANCH" "$BRANCH_W" "$CWD_AHEAD" "$CWD_BEHIND" "$CWD_STAGED" "$CWD_MODIFIED" "$CWD_DELETED" "$CWD_UNTRACKED")
    PRJ_LINE=$(format_dir_line "$DIR" "$DIR_W" "$PRJ_REPO" "$PRJ_REMOTE" "$REPO_W" "$PRJ_BRANCH" "$BRANCH_W" "$PRJ_AHEAD" "$PRJ_BEHIND" "$PRJ_STAGED" "$PRJ_MODIFIED" "$PRJ_DELETED" "$PRJ_UNTRACKED")
else
    # Single line — no padding needed
    gather_git "$DIR" "prj"
    PRJ_REPO=""; [ -n "$G_REMOTE" ] && PRJ_REPO=$(repo_name_from_remote "$G_REMOTE")
    PRJ_LINE=$(format_dir_line "$DIR" "0" "$PRJ_REPO" "$G_REMOTE" "0" "$G_BRANCH" "0" "$G_AHEAD" "$G_BEHIND" "$G_STAGED" "$G_MODIFIED" "$G_DELETED" "$G_UNTRACKED")
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
    printf -v PAD "%${EMPTY}s"
    BAR="${BAR}${PAD// /░}"
fi

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

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
IN_LABEL=$(fmt_tokens "$TOTAL_IN")
OUT_LABEL=$(fmt_tokens "$TOTAL_OUT")
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${YELLOW}${COST_FMT}${RESET} ${DIM}↑${IN_LABEL} ↓${OUT_LABEL}${RESET}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${DIM}${DURATION_FMT}${RESET}"

# ── ccburn display line (optional) ──
# If ccburn is installed, render a single-line usage summary as the bottom row.
# We use --json (not --compact) and format ourselves so we get real pace
# emojis and styling consistent with the rest of the statusline. The compact
# mode only emits ASCII brackets and additionally mis-encodes its separator
# as CP1252 on Windows.
CCBURN_LINE=""
if command -v ccburn >/dev/null 2>&1; then
    CCBURN_JSON=$(timeout 3 ccburn --once --json 2>/dev/null)
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
