#!/system/bin/sh
# Bigme HiBreak / B6 front-light helper (TI LM3630A).
#
# This file is a reference copy. The plugin embeds it (base64) in main.lua and
# installs it to /data/local/tmp/bigme_light.sh on demand, so users never need
# to place it manually.
#
# Usage:
#   bigme_light.sh read_cold | read_warm
#   bigme_light.sh set_cold <0-255> | set_warm <0-255>
#   bigme_light.sh off
DEV=/sys/bus/i2c/devices/2-0036
case "$1" in
  read_cold)  cat "$DEV/lm3630a_cold_light" ;;
  read_warm)  cat "$DEV/lm3630a_warm_light" ;;
  set_cold)   echo "$2" > "$DEV/lm3630a_cold_light" ;;
  set_warm)   echo "$2" > "$DEV/lm3630a_warm_light" ;;
  set_both)   echo "$2" > "$DEV/lm3630a_cold_light"
              echo "$3" > "$DEV/lm3630a_warm_light" ;;
  off)        echo 0 > "$DEV/lm3630a_cold_light"
              echo 0 > "$DEV/lm3630a_warm_light" ;;
  init_perms) chmod 666 "$DEV/lm3630a_cold_light" "$DEV/lm3630a_warm_light" 2>/dev/null ;;
  *)          echo "unknown" ;;
esac
