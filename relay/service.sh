#!/system/bin/sh
# ColorOS guards com.qualcomm.qti.poweroffalarm's receiver with the signature
# permission oplus.permission.OPLUS_COMPONENT_SAFE, so DeskClock's SET_ALARM /
# CANCEL_ALARM broadcasts are dropped and the PMIC RTC is never armed.
# This re-sends them as root, using DeskClock's next alarm-clock time taken
# from AlarmManager. Triggers: DeskClock's denied broadcasts (main path),
# boot, shutdown start, and a 30-minute re-check (safety nets).

MODDIR=${0%/*}
LOG=$MODDIR/relay.log
STATE=$MODDIR/last_set
PKG=com.best.deskclock
POA=com.qualcomm.qti.poweroffalarm
POA_PREFS=/data/user_de/0/$POA/shared_prefs/${POA}_preferences.xml
ACT=org.codeaurora.poweroffalarm.action
LEAD_S=90   # the receiver arms the RTC this many seconds before the alarm

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  # keep the log small
  [ "$(wc -l < "$LOG")" -gt 400 ] && tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

notify() {
  cmd notification post -S bigtext -t "Power-off alarm relay" deskclock_relay "$1" >/dev/null 2>&1
}

# Earliest future DeskClock alarm-clock (the "indicator" alarm set via
# setAlarmClock), in epoch milliseconds; empty if none.
# Uses the AOSP "tag=*walarm*:indicator" line that follows each Alarm{} entry,
# not ColorOS's extra "action ..." text, so ROM format tweaks don't break it.
# awk does the comparison because /system/bin/sh arithmetic is 32-bit.
next_alarm() {
  dumpsys alarm | awk -v now="$(date +%s)000" -v pkg="$PKG}" '
    / origWhen [0-9]+ / && index($0, pkg) {
      for (i = 1; i < NF; i++) if ($i == "origWhen") t = $(i + 1)
      next
    }
    /tag=\*walarm\*:indicator$/ && t != "" && t + 0 > now + 0 {
      if (best == "" || t + 0 < best + 0) best = t
    }
    { t = "" }
    END { if (best != "") print best }'
}

current_slot() {
  sed -n 's/.*name="alarm_time" value="\([0-9]*\)".*/\1/p' "$POA_PREFS" 2>/dev/null
}

set_alarm() {  # $1 = alarm time (ms), $2 = reason
  am broadcast -a $ACT.SET_ALARM -p $POA -f 0x10000000 --el time "$1" >/dev/null 2>&1
  echo "$1" > "$STATE"
  log "set  $1 ($(date -d @"${1%???}" '+%a %m-%d %H:%M')) slot=$(current_slot) [$2]"
}

# Arm DeskClock's next alarm unless the slot already holds it. Never cancels:
# only DeskClock's own CANCEL_ALARM does that. Returns 1 if no alarm found.
ensure_alarm() {  # $1 = reason
  t=$(next_alarm)
  [ -z "$t" ] && return 1
  slot=$(current_slot)
  if [ -n "$slot" ] && [ "${slot%???}" = "$(( ${t%???} - LEAD_S ))" ]; then
    [ "$1" = periodic ] || log "ok   $t already armed [$1]"
    return 0
  fi
  set_alarm "$t" "$1"
}

on_set_denied() {
  sleep 2   # let DeskClock finish rescheduling in AlarmManager
  t=$(next_alarm)
  [ -z "$t" ] && sleep 5 && t=$(next_alarm)
  if [ -n "$t" ]; then
    set_alarm "$t" "deskclock SET"
  else
    # DeskClock asked to arm an alarm but none could be read back: the dumpsys
    # format probably changed. Fail loudly, not silently.
    log "ERROR: DeskClock sent SET_ALARM but no indicator alarm found in dumpsys alarm"
    notify "DeskClock set an alarm but the relay could not read its time, so the phone may NOT switch on for it. Check relay.log in /data/adb/modules/deskclock_poweroff_relay."
  fi
}

on_cancel_denied() {
  sleep 2
  t=$(next_alarm)
  if [ -n "$t" ]; then
    set_alarm "$t" "deskclock CANCEL, next alarm remains"
    return
  fi
  # Only clear the RTC slot if it still holds the alarm we put there.
  last=$(cat "$STATE" 2>/dev/null)
  slot=$(current_slot)
  if [ -n "$last" ] && [ -n "$slot" ] && [ "$slot" != 0 ] \
     && [ "${slot%???}" = "$(( ${last%???} - LEAD_S ))" ]; then
    am broadcast -a $ACT.CANCEL_ALARM -p $POA -f 0x10000000 --el time "$last" >/dev/null 2>&1
    log "cancel (no DeskClock alarm pending) [deskclock CANCEL]"
  else
    log "no DeskClock alarm pending, slot=$slot left as is [deskclock CANCEL]"
  fi
  rm -f "$STATE"
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
log "started"

# DeskClock re-registers its alarms some time after boot (in the test boot
# that was ~1 min later) and doesn't necessarily send SET_ALARM when it does,
# so keep looking for a few minutes.
(
  i=0
  while [ $i -lt 20 ]; do
    ensure_alarm boot && exit 0
    i=$((i + 1)); sleep 15
  done
  log "no DeskClock alarm found within 5 min of boot"
) &

# Safety net for any missed event. Uses monotonic sleep, so it only counts
# time awake; cheap because nothing is sent unless the slot is wrong.
(
  while sleep 1800; do ensure_alarm periodic; done
) &

while true; do
  # Start from "now" so old lines aren't replayed (logcat -T takes a time).
  logcat -b main -b system -v brief -T "$(date '+%m-%d %H:%M:%S.000')" \
         'BroadcastQueue:W' 'ShutdownThread:*' '*:S' 2>/dev/null \
    | while read -r line; do
        case "$line" in
          *"Permission Denial"*"$ACT.SET_ALARM"*"from $PKG "*) on_set_denied ;;
          *"Permission Denial"*"$ACT.CANCEL_ALARM"*"from $PKG "*) on_cancel_denied ;;
          *ShutdownThread*)
            if [ -z "$shutting_down" ]; then
              shutting_down=1
              log "shutdown detected"
              ensure_alarm shutdown || log "no DeskClock alarm pending [shutdown]"
            fi
            ;;
        esac
      done
  log "logcat exited, restarting"
  sleep 5
done
