#!/bin/bash

payload=$(cat)
event=$(jq -r '.hook_event_name // empty' 2>/dev/null <<<"$payload")

case "$event" in
    PermissionRequest) ;;
    Stop)
        [ "$(jq '(.background_tasks // []) | length' 2>/dev/null <<<"$payload")" = 0 ] || exit 0
        ;;
    *) exit 0 ;;
esac

paplay "$2" >/dev/null 2>&1 &
zenity --info --text="$1" >/dev/null 2>&1 &
