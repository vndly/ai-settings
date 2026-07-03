#!/usr/bin/env bash

G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' W=$'\033[37m' N=$'\033[0m'

get_color() {
    local pct=$1
    if ((pct > 80)); then echo "$R"
    elif ((pct > 50)); then echo "$Y"
    else echo "$G"
    fi
}

progress_bar() {
    local pct=$1
    local filled=$((pct / 10))
    ((filled < 0)) && filled=0
    ((filled > 10)) && filled=10
    local color
    color=$(get_color "$pct")
    local bar=""
    for ((i = 0; i < filled; i++)); do bar+='█'; done
    for ((i = filled; i < 10; i++)); do bar+='░'; done
    echo "${color}${bar}${N}"
}

INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model.display_name' | sed 's/ (1M context)//')
CONTEXT_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size')
USAGE=$(echo "$INPUT" | jq '.context_window.current_usage')

WINDOW=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // 0 | round')
RESETS_AT=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // 0')
NOW=$(date +%s)
REMAINING=$((RESETS_AT - NOW))
if [ "$REMAINING" -lt 0 ]; then
    REMAINING=0
fi
HOURS=$((REMAINING / 3600))
MINUTES=$(( (REMAINING % 3600) / 60 ))
WINDOW_TIME=$(printf "(%02d:%02d)" "$HOURS" "$MINUTES")

if [ "$USAGE" != "null" ]; then
    CURRENT_TOKENS=$(echo "$USAGE" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    PERCENT_USED=$((CURRENT_TOKENS * 100 / CONTEXT_SIZE))
    CONTEXT_BAR=$(progress_bar "$PERCENT_USED")
    CONTEXT_COLOR=$(get_color "$PERCENT_USED")
    WINDOW_BAR=$(progress_bar "$WINDOW")
    WINDOW_COLOR=$(get_color "$WINDOW")
    echo "${W}[$MODEL] Context:${N} ${CONTEXT_BAR} ${CONTEXT_COLOR}${PERCENT_USED}%${N}${W} Window:${N} ${WINDOW_BAR} ${WINDOW_COLOR}${WINDOW}%${N} ${W}${WINDOW_TIME}${N}"
else
    CONTEXT_BAR=$(progress_bar 0)
    CONTEXT_COLOR=$(get_color 0)
    WINDOW_BAR=$(progress_bar "$WINDOW")
    WINDOW_COLOR=$(get_color "$WINDOW")
    echo "${W}[$MODEL] Context:${N} ${CONTEXT_BAR} ${CONTEXT_COLOR}0%${N}${W} Window:${N} ${WINDOW_BAR} ${WINDOW_COLOR}${WINDOW}%${N} ${W}${WINDOW_TIME}${N}"
fi