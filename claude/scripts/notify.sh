#!/bin/bash

paplay "$2" >/dev/null 2>&1 &
flock -n "${XDG_RUNTIME_DIR:?}/notify-${PPID}.lock" zenity --info --text="$1" >/dev/null 2>&1 &
