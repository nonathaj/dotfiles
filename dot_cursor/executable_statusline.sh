#!/usr/bin/env bash
# Rich statusline for Cursor CLI
# When CWD == PRJ: 2 lines (project+git, session info)
# When CWD != PRJ: 3 lines (cwd+git, project+git, session info)
#
# Structured to match ~/.claude/statusline.sh (minus Claude-only ccburn).
# See the Claude script for the Windows / Git Bash performance notes.

input=$(cat)
NOW=$(date +%s)

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

# ── Extract JSON fields (single jq call) ──
mapfile -t _F < <(
    printf '%s' "$input" | jq -r '
        .model.display_name // "",
        .model.id // "",
        .model.param_summary // "",
        (.model.max_mode // false),
        .workspace.project_dir // "",
        (.workspace.current_dir // .cwd // ""),
        (.worktree.name // ""),
        ((.context_window.used_percentage // 0) | floor),
        (.context_window.context_window_size // 200000),
        ((.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.output_tokens // 0))),
        (.context_window.total_input_tokens // 0),
        (.context_window.total_output_tokens // 0),
        (.session_name // ""),
        (.autorun // false)
    ' | tr -d '\r'
)
MODEL=${_F[0]}; MODEL_ID=${_F[1]}; PARAM_SUMMARY=${_F[2]}; MAX_MODE=${_F[3]}
DIR=${_F[4]}; CWD=${_F[5]}; WORKTREE_NAME=${_F[6]}
PCT=${_F[7]}; CTX_SIZE=${_F[8]}; CTX_USED=${_F[9]}
TOTAL_IN=${_F[10]}; TOTAL_OUT=${_F[11]}; SESSION_NAME=${_F[12]}; AUTORUN=${_F[13]}

# ── Format token counts (200000 → 200K, 1000000 → 1M) ──
fmt_tokens() {
    local n=$1
    if   [ "$n" -ge 1000000 ] 2>/dev/null; then FMT_OUT="$((n / 1000000))M"
    elif [ "$n" -ge 1000 ]    2>/dev/null; then FMT_OUT="$((n / 1000))K"
    else FMT_OUT="$n"; fi
}
fmt_tokens "$CTX_SIZE"; CTX_LABEL=$FMT_OUT
if [ "$CTX_USED" -eq 0 ] 2>/dev/null && [ "$PCT" -gt 0 ] 2>/dev/null; then
    CTX_USED=$((PCT * CTX_SIZE / 100))
fi
fmt_tokens "$CTX_USED"; CTX_USED_LABEL=$FMT_OUT

# ── Git info gathering (cached per directory) ──
CACHE_MAX_AGE=5

gather_git() {
    local target_dir=$1 suffix=$2
    local cache="/tmp/cursor-statusline-git-cache-${suffix}"
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
            status_out="${status_out//$'\r'/}"
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

pad() {
    local str=$1 width=$2 len=${#1}
    if [ "$width" -gt "$len" ]; then
        local p; printf -v p "%$((width - len))s" ""
        PAD_OUT="${str}${p}"
    else
        PAD_OUT="$str"
    fi
}

repo_name_from_remote() {
    local u=${1%/}
    local head=${u%/*}
    REPO_NAME="${head##*/}/${u##*/}"
}

format_dir_line() {
    local dir_path=$1 dir_w=$2
    local repo=$3 remote=$4 repo_w=$5
    local branch=$6 branch_w=$7
    local ahead=$8 behind=$9 staged=${10} modified=${11} deleted=${12} untracked=${13}

    pad "$dir_path" "$dir_w"; local padded_dir=$PAD_OUT
    local line="${BLUE}${BOLD}${padded_dir}${RESET}"

    if [ "$repo_w" -gt 0 ]; then
        pad "$repo" "$repo_w"; local padded_repo=$PAD_OUT
        if [ -n "$remote" ]; then
            line="${line} ${DIM}│${RESET} ${OSC_OPEN}${remote}${BEL}${CYAN}${padded_repo}${RESET}${OSC_CLOSE}"
        else
            line="${line} ${DIM}│${RESET} ${padded_repo}"
        fi
    fi

    if [ "$branch_w" -gt 0 ]; then
        pad "$branch" "$branch_w"; local padded_branch=$PAD_OUT
        line="${line} ${DIM}│${RESET} ${MAGENTA}${padded_branch}${RESET}"

        local track=""
        [ "$ahead" -gt 0 ] 2>/dev/null && track="${track}${GREEN}↑${ahead}${RESET}"
        [ "$behind" -gt 0 ] 2>/dev/null && track="${track}${RED}↓${behind}${RESET}"
        [ -n "$track" ] && line="${line} ${track}"

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

    DIR_W=${#CWD};           [ ${#DIR} -gt "$DIR_W" ]           && DIR_W=${#DIR}
    REPO_W=${#CWD_REPO};     [ ${#PRJ_REPO} -gt "$REPO_W" ]     && REPO_W=${#PRJ_REPO}
    BRANCH_W=${#CWD_BRANCH}; [ ${#PRJ_BRANCH} -gt "$BRANCH_W" ] && BRANCH_W=${#PRJ_BRANCH}

    format_dir_line "$CWD" "$DIR_W" "$CWD_REPO" "$CWD_REMOTE" "$REPO_W" "$CWD_BRANCH" "$BRANCH_W" "$CWD_AHEAD" "$CWD_BEHIND" "$CWD_STAGED" "$CWD_MODIFIED" "$CWD_DELETED" "$CWD_UNTRACKED"; CWD_LINE=$FMT_DIR_LINE
    format_dir_line "$DIR" "$DIR_W" "$PRJ_REPO" "$PRJ_REMOTE" "$REPO_W" "$PRJ_BRANCH" "$BRANCH_W" "$PRJ_AHEAD" "$PRJ_BEHIND" "$PRJ_STAGED" "$PRJ_MODIFIED" "$PRJ_DELETED" "$PRJ_UNTRACKED"; PRJ_LINE=$FMT_DIR_LINE
else
    gather_git "$DIR" "prj"
    PRJ_REPO=""; [ -n "$G_REMOTE" ] && { repo_name_from_remote "$G_REMOTE"; PRJ_REPO=$REPO_NAME; }
    format_dir_line "$DIR" "0" "$PRJ_REPO" "$G_REMOTE" "0" "$G_BRANCH" "0" "$G_AHEAD" "$G_BEHIND" "$G_STAGED" "$G_MODIFIED" "$G_DELETED" "$G_UNTRACKED"; PRJ_LINE=$FMT_DIR_LINE
fi

# ── Build session line: model | params | context bar | tokens ──
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

PARAM_DISPLAY=""
if [ -n "$PARAM_SUMMARY" ]; then
    _param="${PARAM_SUMMARY#(}"; _param="${_param%)}"
    _model_lc=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')
    _param_lc=$(printf '%s' "$_param" | tr '[:upper:]' '[:lower:]')
    if [[ "$_model_lc" != *"$_param_lc"* ]]; then
        PARAM_DISPLAY="${DIM}${PARAM_SUMMARY}${RESET}"
    fi
fi
if [ "$MAX_MODE" = "true" ]; then
    PARAM_DISPLAY="${PARAM_DISPLAY}${PARAM_DISPLAY:+ }${BOLD}${YELLOW}◉ max${RESET}"
fi

SESSION_LINE="${CYAN}${MODEL}${RESET}"
[ -n "$PARAM_DISPLAY" ] && SESSION_LINE="${SESSION_LINE} ${PARAM_DISPLAY}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${BAR_COLOR}${BAR}${RESET} ${PCT}% ${DIM}${CTX_USED_LABEL}/${CTX_LABEL}${RESET}"
fmt_tokens "$TOTAL_IN";  IN_LABEL=$FMT_OUT
fmt_tokens "$TOTAL_OUT"; OUT_LABEL=$FMT_OUT
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${DIM}↑${IN_LABEL} ↓${OUT_LABEL}${RESET}"

if [ -n "$SESSION_NAME" ]; then
    SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${WHITE}${SESSION_NAME}${RESET}"
fi
if [ "$AUTORUN" = "true" ]; then
    SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${GREEN}auto${RESET}"
fi
if [ -n "$WORKTREE_NAME" ]; then
    SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${MAGENTA}wt:${WORKTREE_NAME}${RESET}"
fi

# ── Output ──
if [ -n "$CWD_LINE" ]; then
    printf '%s\n' "${DIM}cwd:${RESET} $CWD_LINE"
    printf '%s\n' "${DIM}prj:${RESET} $PRJ_LINE"
else
    printf '%s\n' "$PRJ_LINE"
fi
printf '%s\n' "$SESSION_LINE"

exit 0
