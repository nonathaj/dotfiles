#!/usr/bin/env bash
# Rich statusline for Google Antigravity CLI (agy) & Claude Code
# When CWD == PRJ: 2 lines (project+git, session info)
# When CWD != PRJ: 3 lines (cwd+git, project+git, session info)

IFS= read -rd '' input || true   # slurp stdin without spawning `cat`
NOW=$(date +%s)                  # one clock read

find_git_root() {
    local d=$1
    d="${d//\\//}"
    while [ -n "$d" ] && [ "$d" != "." ] && [ "$d" != "/" ] && [[ ! "$d" =~ ^[A-Za-z]:/?$ ]]; do
        if [ -d "$d/.git" ]; then
            if [[ "$1" =~ \\ ]]; then
                echo "${d//\//\\}"
            else
                echo "$d"
            fi
            return 0
        fi
        d=$(dirname "$d")
    done
    echo "$1"
}

# Parse CWD and DIR first to normalize workspace directories
mapfile -t _T < <(
    printf '%s' "$input" | jq -r '
        .cwd // .workspace.current_dir // "",
        .workspace.project_dir // ""
    ' | tr -d '\r'
)
CWD=${_T[0]}
DIR=${_T[1]}

if [ -z "$DIR" ] && [ -n "$CWD" ]; then
    DIR=$(find_git_root "$CWD")
fi

# Normalize input JSON so the rest of the script gets a unified format
input=$(printf '%s' "$input" | jq \
    --arg cwd "$CWD" \
    --arg dir "$DIR" \
    '
    .workspace.current_dir = $cwd |
    .workspace.project_dir = $dir
    '
)

# ── Colors ──
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
mapfile -t _F < <(
    printf '%s' "$input" | jq -r '
        .model.display_name // "",
        .model.id // "",
        .workspace.project_dir // "",
        .workspace.current_dir // "",
        ((.context_window.used_percentage // 0) | floor),
        (.context_window.context_window_size // 2000000),
        ((.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))),
        (.context_window.total_input_tokens // 0),
        (.context_window.total_output_tokens // 0),
        (.cost.total_duration_ms // 0)
    ' | tr -d '\r'
)
MODEL=${_F[0]}; MODEL_ID=${_F[1]}; DIR=${_F[2]}; CWD=${_F[3]}
PCT=${_F[4]}; CTX_SIZE=${_F[5]}; CTX_USED=${_F[6]}
TOTAL_IN=${_F[7]}; TOTAL_OUT=${_F[8]}; DURATION_MS=${_F[9]}

[ -z "$MODEL" ] && MODEL=$MODEL_ID
if [ "$CTX_USED" -eq 0 ] && [ "$TOTAL_IN" -gt 0 ]; then
    CTX_USED=$TOTAL_IN
fi

# ── Format token counts ──
fmt_tokens() {
    local n=$1
    if   [ "$n" -ge 1000000 ] 2>/dev/null; then FMT_OUT="$((n / 1000000))M"
    elif [ "$n" -ge 1000 ]    2>/dev/null; then FMT_OUT="$((n / 1000))K"
    else FMT_OUT="$n"; fi
}
fmt_tokens "$CTX_SIZE"; CTX_LABEL=$FMT_OUT
fmt_tokens "$CTX_USED"; CTX_USED_LABEL=$FMT_OUT

# ── Git info gathering ──
CACHE_MAX_AGE=5

gather_git() {
    local target_dir=$1 suffix=$2
    local cache="/tmp/agy-statusline-git-cache-${suffix}"
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
if [ "$CWD" != "$DIR" ] && [ -n "$CWD" ] && [ -n "$DIR" ]; then
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
    # Single line
    gather_git "$DIR" "prj"
    PRJ_REPO=""; [ -n "$G_REMOTE" ] && { repo_name_from_remote "$G_REMOTE"; PRJ_REPO=$REPO_NAME; }
    format_dir_line "$DIR" "0" "$PRJ_REPO" "$G_REMOTE" "0" "$G_BRANCH" "0" "$G_AHEAD" "$G_BEHIND" "$G_STAGED" "$G_MODIFIED" "$G_DELETED" "$G_UNTRACKED"; PRJ_LINE=$FMT_DIR_LINE
fi

# ── Build session line ──
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

SESSION_LINE="${CYAN}${MODEL}${RESET}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${BAR_COLOR}${BAR}${RESET} ${PCT}% ${DIM}${CTX_USED_LABEL}/${CTX_LABEL}${RESET}"
fmt_tokens "$TOTAL_IN";  IN_LABEL=$FMT_OUT
fmt_tokens "$TOTAL_OUT"; OUT_LABEL=$FMT_OUT
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${DIM}↑${IN_LABEL} ↓${OUT_LABEL}${RESET}"
SESSION_LINE="${SESSION_LINE} ${DIM}│${RESET} ${DIM}${DURATION_FMT}${RESET}"

# ── agy quota line (native weekly usage straight from the statusline payload) ──
# No external tool / cache / background job: .quota is present on every render.
# Shows used% (1 - remaining_fraction) per bucket, colored/iconed by utilization.
QUOTA_LINE=$(printf '%s' "$input" | jq -r \
    --arg sep " ${DIM}│${RESET}  " \
    --arg dim "$DIM" --arg reset "$RESET" \
    --arg green "$GREEN" --arg yellow "$YELLOW" --arg red "$RED" '
    def icon(u):  if u >= 0.9 then "🚨" elif u >= 0.7 then "🔥" else "🧊" end;
    def color(u): if u >= 0.9 then $red elif u >= 0.7 then $yellow else $green end;
    def fmt_reset(s):
        if s == null or s <= 0 then ""
        else (s / 86400 | floor) as $d | ((s % 86400) / 3600 | floor) as $h |
            (if   $d > 0 then "\($d)d\($h)h"
             elif $h > 0 then "\($h)h\(((s % 3600) / 60 | floor))m"
             else            "\((s / 60 | floor))m" end)
        end;
    (.quota // {}) | to_entries
    | map( (1 - (.value.remaining_fraction // 1)) as $u |
           "\(icon($u)) \(.key) \(color($u))\(($u * 100) | round)%\($reset) \($dim)(\(fmt_reset(.value.reset_in_seconds)))\($reset)" )
    | join($sep)
' 2>/dev/null)

# ── Output ──
if [ -n "$CWD_LINE" ]; then
    printf '%s\n' "${DIM}cwd:${RESET} $CWD_LINE"
    printf '%s\n' "${DIM}prj:${RESET} $PRJ_LINE"
else
    printf '%s\n' "$PRJ_LINE"
fi
printf '%s\n' "$SESSION_LINE"
[ -n "$QUOTA_LINE" ] && printf '%s\n' "$QUOTA_LINE"

exit 0
