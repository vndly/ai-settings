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

IFS=$'\t' read -r MODEL CONTEXT_PCT QUOTA_PCT RESETS_AT <<< "$(echo "$INPUT" | jq -r '
. as $root
| ($root.model.display_name // $root.model.id // "Gemini") as $model
| (
    if $root.context_window.used_percentage != null then
      ($root.context_window.used_percentage | round)
    elif (($root.context_window.context_window_size // 0) > 0) then
      (
        ($root.context_window.total_input_tokens // (
          ($root.context_window.current_usage.input_tokens // 0) +
          ($root.context_window.current_usage.cache_creation_input_tokens // 0) +
          ($root.context_window.current_usage.cache_read_input_tokens // 0)
        ) // 0) * 100 / $root.context_window.context_window_size
      ) | round
    else
      0
    end
  ) as $context_pct
| (
    if $root.quota.used_percentage != null then
      ($root.quota.used_percentage | round)
    elif $root.quota.remaining_fraction != null then
      (((1.0 - $root.quota.remaining_fraction) * 100) | round)
    else
      ""
    end
  ) as $quota_pct
| (
    if $root.quota.reset_time != null then
      $root.quota.reset_time
    elif $root.quota.resets_at != null then
      $root.quota.resets_at
    else
      ""
    end
  ) as $resets_at
| "\($model)\t\($context_pct)\t\($quota_pct)\t\($resets_at)"
')"

CONTEXT_PCT=${CONTEXT_PCT:-0}
CONTEXT_BAR=$(progress_bar "$CONTEXT_PCT")
CONTEXT_COLOR=$(get_color "$CONTEXT_PCT")

OUTPUT="${W}[$MODEL] Context:${N} ${CONTEXT_BAR} ${CONTEXT_COLOR}${CONTEXT_PCT}%${N}"

if [ -n "$QUOTA_PCT" ]; then
    QUOTA_BAR=$(progress_bar "$QUOTA_PCT")
    QUOTA_COLOR=$(get_color "$QUOTA_PCT")
    QUOTA_TIME=""
    if [ -n "$RESETS_AT" ] && [ "$RESETS_AT" -gt 0 ] 2>/dev/null; then
        NOW=$(date +%s)
        REMAINING=$((RESETS_AT - NOW))
        ((REMAINING < 0)) && REMAINING=0
        HOURS=$((REMAINING / 3600))
        MINUTES=$(((REMAINING % 3600) / 60))
        QUOTA_TIME=" $(printf "(%02d:%02d)" "$HOURS" "$MINUTES")"
    fi
    OUTPUT="${OUTPUT}${W} Quota:${N} ${QUOTA_BAR} ${QUOTA_COLOR}${QUOTA_PCT}%${N}${W}${QUOTA_TIME}${N}"
fi

echo "$OUTPUT"
