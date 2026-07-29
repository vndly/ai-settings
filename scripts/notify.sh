#!/bin/bash

paplay "$2" >/dev/null 2>&1 &
zenity --info --text="$1" >/dev/null 2>&1 &