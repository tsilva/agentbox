#!/bin/bash
#
# style.sh - Terminal styling library
#
# Source this file in shell scripts for gorgeous terminal output.
# Uses gum (charmbracelet) for borders, spinners, and interactive widgets.
# Falls back to ANSI 256-color + Unicode for everything else.
#
# Usage: [[ -f style.sh ]] && source style.sh || true
#

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

# Respect NO_COLOR (https://no-color.org) and non-TTY output
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 2 ]]; then
    _STYLE_HAS_COLOR=false
else
    _STYLE_HAS_COLOR=true
fi

# Truecolor detection
_STYLE_HAS_TRUECOLOR=false
if [[ "$_STYLE_HAS_COLOR" == true ]]; then
    case "${COLORTERM:-}" in
        truecolor|24bit) _STYLE_HAS_TRUECOLOR=true ;;
    esac
fi

# Detect gum
if command -v gum &> /dev/null && [[ "$_STYLE_HAS_COLOR" == true ]]; then
    _STYLE_HAS_GUM=true
else
    _STYLE_HAS_GUM=false
fi

# Dynamic terminal width
_STYLE_COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 60)}"

# Verbosity: 0=quiet, 1=default, 2=verbose
_STYLE_VERBOSITY="${STYLE_VERBOSE:-1}"

# ---------------------------------------------------------------------------
# ANSI color palette
# ---------------------------------------------------------------------------

if [[ "$_STYLE_HAS_COLOR" == true ]]; then
    if [[ "$_STYLE_HAS_TRUECOLOR" == true ]]; then
        _C_BRAND=$'\033[38;2;175;135;255m'    # #AF87FF soft purple
        _C_SUCCESS=$'\033[38;2;135;215;135m'  # #87D787 soft green
        _C_ERROR=$'\033[38;2;255;95;95m'      # #FF5F5F warm red
        _C_WARN=$'\033[38;2;255;215;95m'      # #FFD75F amber
        _C_INFO=$'\033[38;2;135;206;235m'     # #87CEEB sky blue
        _C_MUTED=$'\033[38;2;128;128;128m'    # #808080 gray
    else
        _C_BRAND=$'\033[38;5;141m'    # #AF87FF soft purple
        _C_SUCCESS=$'\033[38;5;114m'  # #87D787 soft green
        _C_ERROR=$'\033[38;5;203m'    # #FF5F5F warm red
        _C_WARN=$'\033[38;5;221m'     # #FFD75F amber
        _C_INFO=$'\033[38;5;117m'     # #87CEEB sky blue
        _C_MUTED=$'\033[38;5;244m'    # #808080 gray
    fi
    _C_BOLD=$'\033[1m'
    _C_ITALIC=$'\033[3m'
    _C_UNDERLINE=$'\033[4m'
    _C_RESET=$'\033[0m'
else
    _C_BRAND="" _C_SUCCESS="" _C_ERROR="" _C_WARN="" _C_INFO="" _C_MUTED=""
    _C_BOLD="" _C_ITALIC="" _C_UNDERLINE="" _C_RESET=""
fi

# ---------------------------------------------------------------------------
# Output functions
# ---------------------------------------------------------------------------

# header "brand" "subtitle" — Bordered header with brand color
header() {
    local title="${1:-}" subtitle="${2:-}"
    local full_text="$title"
    [[ -n "$subtitle" ]] && full_text="$title  $subtitle"

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        local width=${#full_text}
        (( width < 36 )) && width=36
        (( width += 4 ))
        gum style \
            --border rounded \
            --border-foreground 141 \
            --foreground 141 \
            --bold \
            --padding "0 2" \
            --margin "0 0" \
            --width "$width" \
            --align center \
            "$full_text" >&2
    else
        local len=${#full_text}
        local pad=4
        local total=$((len + pad))
        local line
        line=$(printf '━%.0s' $(seq 1 "$total"))
        echo "" >&2
        echo "${_C_BRAND}┏${line}┓${_C_RESET}" >&2
        echo "${_C_BRAND}┃${_C_RESET}  ${_C_BRAND}${_C_BOLD}${full_text}${_C_RESET}  ${_C_BRAND}┃${_C_RESET}" >&2
        echo "${_C_BRAND}┗${line}┛${_C_RESET}" >&2
    fi
    echo "" >&2
}

# section "text" — Horizontal rule section divider (━━ text ━━━━)
section() {
    local text="${1:-}"
    local prefix="━━ ${text} "
    local prefix_len=$(( 4 + ${#text} ))
    local trail_len=$(( _STYLE_COLS - prefix_len ))
    (( trail_len < 4 )) && trail_len=4
    local trail
    trail=$(printf '━%.0s' $(seq 1 "$trail_len"))

    echo "" >&2
    echo "${_C_BRAND}${_C_BOLD}${prefix}${trail}${_C_RESET}" >&2
    echo "" >&2
}

# success "text" — ✓ green text
success() {
    echo "  ${_C_SUCCESS}✓${_C_RESET} ${_C_SUCCESS}$1${_C_RESET}" >&2
}

# error "text" — ✗ red text
error() {
    echo "  ${_C_ERROR}✗${_C_RESET} ${_C_ERROR}$1${_C_RESET}" >&2
}

# warn "text" — ⚠ amber text
warn() {
    echo "  ${_C_WARN}⚠${_C_RESET} ${_C_WARN}$1${_C_RESET}" >&2
}

# info "text" — ● blue text
info() {
    echo "  ${_C_INFO}●${_C_RESET} ${_C_INFO}$1${_C_RESET}" >&2
}

# step "text" — → dimmed action log (suppressed in quiet mode)
step() {
    [[ "$_STYLE_VERBOSITY" -eq 0 ]] && return 0
    echo "  ${_C_MUTED}→ $1${_C_RESET}" >&2
}

# note "text" — gray "Note:" prefix
note() {
    echo "  ${_C_MUTED}Note: $1${_C_RESET}" >&2
}

# confirm "prompt" [timeout_seconds] [affirmative] [negative]
# Styled y/n prompt. Sets REPLY variable.
confirm() {
    local prompt="${1:-Continue?}"
    local timeout="${2:-}"
    local affirmative="${3:-}"
    local negative="${4:-}"

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        local -a gum_args=(--prompt.foreground 141)
        [[ -n "$timeout" ]] && gum_args+=(--timeout "${timeout}s")
        [[ -n "$affirmative" ]] && gum_args+=(--affirmative "$affirmative")
        [[ -n "$negative" ]] && gum_args+=(--negative "$negative")
        if gum confirm "${gum_args[@]}" "$prompt"; then
            REPLY="y"
        else
            REPLY="n"
        fi
    else
        local suffix="(y/n)"
        [[ -n "$affirmative" && -n "$negative" ]] && suffix="($affirmative/$negative)"
        printf "  ${_C_BRAND}▸${_C_RESET} %s ${_C_MUTED}%s${_C_RESET} " "$prompt" "$suffix" >&2
        if [[ -n "$timeout" ]]; then
            read -t "$timeout" -n 1 -r || REPLY="n"
        else
            read -n 1 -r
        fi
        echo "" >&2
    fi
}

# banner "text" — Bordered completion message
banner() {
    local text="${1:-}"

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        local width=${#text}
        (( width < 36 )) && width=36
        (( width += 4 ))
        echo "" >&2
        gum style \
            --border rounded \
            --border-foreground 114 \
            --foreground 114 \
            --bold \
            --padding "0 2" \
            --margin "0 0" \
            --width "$width" \
            --align center \
            "$text" >&2
    else
        local len=${#text}
        local pad=4
        local total=$((len + pad))
        local line
        line=$(printf '━%.0s' $(seq 1 "$total"))
        echo "" >&2
        echo "${_C_SUCCESS}┏${line}┓${_C_RESET}" >&2
        echo "${_C_SUCCESS}┃${_C_RESET}  ${_C_SUCCESS}${_C_BOLD}${text}${_C_RESET}  ${_C_SUCCESS}┃${_C_RESET}" >&2
        echo "${_C_SUCCESS}┗${line}┛${_C_RESET}" >&2
    fi
    echo "" >&2
}

# error_block "line1" "line2" ... — Multi-line error with red left border
error_block() {
    echo "" >&2
    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        local content=""
        for line in "$@"; do
            [[ -n "$content" ]] && content+=$'\n'
            content+="$line"
        done
        gum style \
            --border thick \
            --border-foreground 203 \
            --foreground 203 \
            --padding "0 1" \
            --margin "0 1" \
            "$content" >&2
    else
        for line in "$@"; do
            echo "  ${_C_ERROR}│${_C_RESET} ${_C_ERROR}$line${_C_RESET}" >&2
        done
    fi
    echo "" >&2
}

# list_item "label" "value" — Colored label: value pair
list_item() {
    local label="${1:-}" value="${2:-}"
    echo "  ${_C_BRAND}•${_C_RESET} ${_C_BRAND}${_C_BOLD}$label:${_C_RESET} ${_C_MUTED}$value${_C_RESET}" >&2
}

# dim "text" — Gray/muted text (suppressed in quiet mode)
dim() {
    [[ "$_STYLE_VERBOSITY" -eq 0 ]] && return 0
    echo "  ${_C_MUTED}$1${_C_RESET}" >&2
}

# ---------------------------------------------------------------------------
# Interactive functions
# ---------------------------------------------------------------------------

# spin "title" command [args...] — Wrap a command with an animated spinner
# Returns the wrapped command's exit code.
spin() {
    local title="$1"; shift

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        gum spin --spinner dot --title "  $title" --show-error -- "$@"
        return $?
    else
        # ANSI fallback: show title, run command, overwrite with result
        local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local pid exit_code

        # Run command in background, capture output
        local tmpfile
        tmpfile=$(mktemp "${TMPDIR:-/tmp}/style_spin.XXXXXX")
        "$@" > "$tmpfile" 2>&1 &
        pid=$!

        # Animate spinner while command runs
        local i=0
        while kill -0 "$pid" 2>/dev/null; do
            local char="${spin_chars:i%${#spin_chars}:1}"
            printf "\r  ${_C_INFO}%s${_C_RESET} %s" "$char" "$title" >&2
            ((i++))
            sleep 0.1
        done

        wait "$pid"
        exit_code=$?

        # Overwrite spinner line with result
        if [[ $exit_code -eq 0 ]]; then
            printf "\r  ${_C_SUCCESS}✓${_C_RESET} %s\033[K\n" "$title" >&2
        else
            printf "\r  ${_C_ERROR}✗${_C_RESET} %s\033[K\n" "$title" >&2
            # Show captured output on failure
            if [[ -s "$tmpfile" ]]; then
                while IFS= read -r line; do
                    echo "    ${_C_MUTED}${line}${_C_RESET}" >&2
                done < "$tmpfile"
            fi
        fi

        rm -f "$tmpfile"
        return $exit_code
    fi
}

# table "col1,col2" "val1,val2" ... — Formatted table display
table() {
    [[ $# -lt 2 ]] && return 1
    local header_row="$1"; shift

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        {
            echo "$header_row"
            for row in "$@"; do
                echo "$row"
            done
        } | gum table --border.foreground 141 --header.foreground 141 --header.bold >&2
        return $?
    else
        # ANSI fallback: calculate column widths, render with box-drawing
        local -a rows=("$header_row" "$@")
        local -a col_widths=()

        # Parse all rows and find max widths
        for row in "${rows[@]}"; do
            local col_idx=0
            IFS=',' read -ra cells <<< "$row"
            for cell in "${cells[@]}"; do
                local len=${#cell}
                if [[ ${col_widths[$col_idx]:-0} -lt $len ]]; then
                    col_widths[col_idx]=$len
                fi
                ((col_idx++))
            done
        done

        local num_cols=${#col_widths[@]}

        # Build horizontal lines
        local top_line="  ┌" mid_line="  ├" bot_line="  └"
        for (( c=0; c<num_cols; c++ )); do
            local w=$(( col_widths[c] + 2 ))
            local seg
            seg=$(printf '─%.0s' $(seq 1 "$w"))
            if (( c < num_cols - 1 )); then
                top_line+="${seg}┬"
                mid_line+="${seg}┼"
                bot_line+="${seg}┴"
            else
                top_line+="${seg}┐"
                mid_line+="${seg}┤"
                bot_line+="${seg}┘"
            fi
        done

        echo "${_C_MUTED}${top_line}${_C_RESET}" >&2

        # Print rows
        local row_idx=0
        for row in "${rows[@]}"; do
            IFS=',' read -ra cells <<< "$row"
            local line="  │"
            for (( c=0; c<num_cols; c++ )); do
                local cell="${cells[$c]:-}"
                local w=${col_widths[$c]}
                if (( row_idx == 0 )); then
                    line+=" ${_C_BRAND}${_C_BOLD}$(printf "%-${w}s" "$cell")${_C_RESET} │"
                else
                    line+=" ${_C_MUTED}$(printf "%-${w}s" "$cell")${_C_RESET} │"
                fi
            done
            echo "${_C_MUTED}${line}${_C_RESET}" >&2

            # Separator after header
            if (( row_idx == 0 )); then
                echo "${_C_MUTED}${mid_line}${_C_RESET}" >&2
            fi
            ((row_idx++))
        done

        echo "${_C_MUTED}${bot_line}${_C_RESET}" >&2
    fi
}

# choose "header" "option1" "option2" ... — Interactive selection menu
# Returns selected value via stdout.
choose() {
    local hdr="$1"; shift

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        gum choose --header "  $hdr" --cursor "  ▸ " \
            --header.foreground 141 --cursor.foreground 141 \
            "$@"
        return $?
    else
        # ANSI fallback: numbered list with read prompt
        echo "  ${_C_BRAND}${_C_BOLD}${hdr}${_C_RESET}" >&2
        local i=1
        for opt in "$@"; do
            echo "  ${_C_MUTED}${i})${_C_RESET} $opt" >&2
            ((i++))
        done
        local total=$#
        local choice
        while true; do
            printf "  ${_C_BRAND}▸${_C_RESET} ${_C_MUTED}[1-%d]:${_C_RESET} " "$total" >&2
            read -r choice < /dev/tty
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
                break
            fi
            echo "  ${_C_ERROR}Invalid choice${_C_RESET}" >&2
        done
        # Return the selected option via stdout
        local idx=1
        for opt in "$@"; do
            if (( idx == choice )); then
                echo "$opt"
                return 0
            fi
            ((idx++))
        done
    fi
}

# input "prompt" [placeholder] [--password] — Styled text input
# Returns value via stdout.
input() {
    local prompt="${1:-}" placeholder="${2:-}" password=false
    # Check for --password flag in any position
    for arg in "$@"; do
        [[ "$arg" == "--password" ]] && password=true
    done

    if [[ "$_STYLE_HAS_GUM" == true ]]; then
        local -a gum_args=(--prompt "  $prompt " --prompt.foreground 141)
        [[ -n "$placeholder" && "$placeholder" != "--password" ]] && gum_args+=(--placeholder "$placeholder")
        if [[ "$password" == true ]]; then
            gum input "${gum_args[@]}" --password
        else
            gum input "${gum_args[@]}"
        fi
        return $?
    else
        printf "  ${_C_BRAND}▸${_C_RESET} %s " "$prompt" >&2
        if [[ -n "$placeholder" && "$placeholder" != "--password" ]]; then
            printf "${_C_MUTED}(%s)${_C_RESET} " "$placeholder" >&2
        fi
        local value
        if [[ "$password" == true ]]; then
            read -rs value < /dev/tty
            echo "" >&2
        else
            read -r value < /dev/tty
        fi
        echo "$value"
    fi
}

# progress current total [label] — Inline progress bar for loops
# Usage: for i in $(seq 1 $total); do progress $i $total "Processing"; done
progress() {
    local current="${1:-0}" total="${2:-100}" label="${3:-}"
    (( total <= 0 )) && total=1

    local pct=$(( current * 100 / total ))
    (( pct > 100 )) && pct=100

    local bar_width=$(( _STYLE_COLS - 20 - ${#label} ))
    (( bar_width < 10 )) && bar_width=10
    (( bar_width > 40 )) && bar_width=40

    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled bar_empty
    bar_filled=$(printf '█%.0s' $(seq 1 "$filled") 2>/dev/null)
    bar_empty=$(printf '░%.0s' $(seq 1 "$empty") 2>/dev/null)

    if [[ "$_STYLE_HAS_COLOR" == true ]]; then
        printf "\r  ${_C_BRAND}%s${_C_MUTED}%s${_C_RESET}  ${_C_BOLD}%3d%%${_C_RESET} %s" \
            "$bar_filled" "$bar_empty" "$pct" "$label" >&2
    else
        printf "\r  %s%s  %3d%% %s" "$bar_filled" "$bar_empty" "$pct" "$label" >&2
    fi

    # Newline on completion
    if (( current >= total )); then
        echo "" >&2
    fi
}
