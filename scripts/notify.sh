#!/bin/bash

paplay $2 &
(zenity --info --text="$1" && wmctrl -x -a code) &