#!/system/bin/sh
# ColorOS guards com.qualcomm.qti.poweroffalarm's receiver with the signature
# permission oplus.permission.OPLUS_COMPONENT_SAFE, so DeskClock's SET_ALARM /
# CANCEL_ALARM broadcasts are dropped and the PMIC RTC is never armed.
# This re-sends them as root, using DeskClock's next alarm-clock time taken
# from AlarmManager, or from DeskClock's own alarm instances while the user is
# locked (before the first unlock DeskClock 2.34 registers no alarm clock and
# only ever sends CANCEL_ALARM). Triggers: DeskClock's denied broadcasts (main
# path), boot, shutdown start, and a 30-minute re-check (safety nets).

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

# DeskClock's next alarm in epoch milliseconds; empty if none.
# Prefers what DeskClock itself registered with AlarmManager; while the user is
# locked (Direct Boot) DeskClock 2.34 registers nothing, so fall back to its
# alarm instances.
next_alarm() {
  t=$(indicator_alarm)
  [ -z "$t" ] && t=$(provider_alarm)
  echo "$t"
}

# Earliest future DeskClock alarm-clock (the "indicator" alarm set via
# setAlarmClock), in epoch milliseconds; empty if none.
# Uses the AOSP "tag=*walarm*:indicator" line that follows each Alarm{} entry,
# not ColorOS's extra "action ..." text, so ROM format tweaks don't break it.
# awk does the comparison because /system/bin/sh arithmetic is 32-bit.
indicator_alarm() {
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

# Earliest future DeskClock alarm instance, read through DeskClock's content
# provider (it lives in device-protected storage, so this works before the first
# unlock; root may query it although it isn't exported). States 0-2 are
# silent/notification/snoozed, the same filter as getNextFiringAlarm(); month is
# 0-based like java.util.Calendar.
provider_alarm() {
  now=$(date +%s)
  content query --uri "content://$PKG/instances" \
      --projection year:month:day:hour:minutes --where 'alarm_state<3' 2>/dev/null \
    | sed -n 's/.*year=\([0-9]*\), month=\([0-9]*\), day=\([0-9]*\), hour=\([0-9]*\), minutes=\([0-9]*\).*/\1 \2 \3 \4 \5/p' \
    | while read -r y mo d h mi; do
        s=$(date -d "$(printf '%04d-%02d-%02d %02d:%02d:00' "$y" $((mo + 1)) "$d" "$h" "$mi")" +%s 2>/dev/null)
        [ -n "$s" ] && [ "$s" -gt "$now" ] && echo "$s"
      done \
    | sort -n | head -n 1 | sed 's/$/000/'
}

locked() {
  [ "$(getprop sys.user.0.ce_available)" != true ]
}

current_slot() {
  sed -n 's/.*name="alarm_time" value="\([0-9]*\)".*/\1/p' "$POA_PREFS" 2>/dev/null
}

set_alarm() {  # $1 = alarm time (ms), $2 = reason
  am broadcast -a $ACT.SET_ALARM -p $POA -f 0x10000000 --el time "$1" >/dev/null 2>&1
  echo "$1" > "$STATE"
  log "set  $1 ($(date -d @"${1%???}" '+%a %m-%d %H:%M')) slot=$(current_slot) [$2]$(locked && echo ' (locked)')"
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
    # or provider format probably changed. Fail loudly, not silently.
    log "ERROR: DeskClock sent SET_ALARM but no alarm found in dumpsys alarm or its provider"
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
