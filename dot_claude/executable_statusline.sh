#!/usr/bin/env bash
# Rich statusline for Claude Code
# When CWD == PRJ: 2 lines (project+git, session info)
# When CWD != PRJ: 3 lines (cwd+git, project+git, session info)

input=$(cat)

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
        if git -C "$target_dir" rev-parse --git-dir > /dev/null 2>&1; then
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

# Format a directory line with git info
# Usage: format_dir_line <directory_path>
# Reads from G_* variables (call gather_git first)
format_dir_line() {
    local dir_path=$1
    local line="${BLUE}${BOLD}${dir_path}${RESET}"

    # GitHub repo link (OSC 8 clickable)
    if [ -n "$G_REMOTE" ]; then
        local repo_name=$(echo "$G_REMOTE" | sed 's|.*/\([^/]*/[^/]*\)$|\1|')
        line="${line} ${DIM}│${RESET} ${OSC_OPEN}${G_REMOTE}${BEL}${CYAN}${repo_name}${RESET}${OSC_CLOSE}"
    fi

    # Git branch
    if [ -n "$G_BRANCH" ]; then
        line="${line} ${DIM}│${RESET} ${MAGENTA}${G_BRANCH}${RESET}"

        # Ahead/behind tracking branch
        local track=""
        [ "$G_AHEAD" -gt 0 ] 2>/dev/null && track="${track}${GREEN}↑${G_AHEAD}${RESET}"
        [ "$G_BEHIND" -gt 0 ] 2>/dev/null && track="${track}${RED}↓${G_BEHIND}${RESET}"
        [ -n "$track" ] && line="${line} ${track}"

        # Git status indicators
        local status=""
        [ "$G_STAGED" -gt 0 ] 2>/dev/null && status="${status} ${GREEN}+${G_STAGED}${RESET}"
        [ "$G_MODIFIED" -gt 0 ] 2>/dev/null && status="${status} ${YELLOW}~${G_MODIFIED}${RESET}"
        [ "$G_DELETED" -gt 0 ] 2>/dev/null && status="${status} ${RED}-${G_DELETED}${RESET}"
        [ "$G_UNTRACKED" -gt 0 ] 2>/dev/null && status="${status} ${DIM}?${G_UNTRACKED}${RESET}"

        if [ -z "$status" ]; then
            line="${line} ${GREEN}✓${RESET}"
        else
            line="${line}${status}"
        fi
    fi

    echo "$line"
}

# ── Build directory lines ──
gather_git "$DIR" "prj"
PRJ_LINE=$(format_dir_line "$DIR")

CWD_LINE=""
if [ "$CWD" != "$DIR" ] && [ -n "$CWD" ]; then
    gather_git "$CWD" "cwd"
    CWD_LINE=$(format_dir_line "$CWD")
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

# ── Output ──
if [ -n "$CWD_LINE" ]; then
    printf '%s\n' "${DIM}cwd:${RESET} $CWD_LINE"
    printf '%s\n' "${DIM}prj:${RESET} $PRJ_LINE"
else
    printf '%s\n' "$PRJ_LINE"
fi
printf '%s\n' "$SESSION_LINE"
