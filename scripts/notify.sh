#!/bin/bash

paplay "$2" >/dev/null 2>&1 &
(zenity --info --text="$1" && wmctrl -x -a code) >/dev/null 2>&1 </dev/null &