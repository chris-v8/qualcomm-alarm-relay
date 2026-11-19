#!/system/bin/sh
# ColorOS guards com.qualcomm.qti.poweroffalarm's receiver with the signature
# permission oplus.permission.OPLUS_COMPONENT_SAFE, so DeskClock's SET_ALARM /
# CANCEL_ALARM broadcasts are dropped and the PMIC RTC is never armed.
# This watches for those denials and re-sends the request as root, using
# DeskClock's next alarm-clock time taken from AlarmManager.

MODDIR=${0%/*}
LOG=$MODDIR/relay.log
STATE=$MODDIR/last_set
PKG=com.best.deskclock
POA=com.qualcomm.qti.poweroffalarm
POA_PREFS=/data/user_de/0/$POA/shared_prefs/${POA}_preferences.xml
ACT=org.codeaurora.poweroffalarm.action
LEAD_MS=90000   # the receiver arms the RTC this much before the alarm

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
  # keep the log small
  [ "$(wc -l < "$LOG")" -gt 400 ] && tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# Earliest future DeskClock alarm-clock (the "indicator" alarm set via
# setAlarmClock), in epoch milliseconds; empty if none.
# Times are compared in seconds because /system/bin/sh arithmetic is 32-bit.
next_alarm() {
  now=$(date +%s)
  dumpsys alarm \
    | sed -n "s/.*origWhen \([0-9]\{13\}\) .*$PKG}.* action indicator .*/\1/p" \
    | sort -u \
    | while read -r t; do
        [ "${t%???}" -gt "$now" ] && echo "$t"
      done \
    | head -n 1
}

current_slot() {
  sed -n 's/.*name="alarm_time" value="\([0-9]*\)".*/\1/p' "$POA_PREFS" 2>/dev/null
}

sync_alarm() {
  t=$(next_alarm)
  if [ -n "$t" ]; then
    am broadcast -a $ACT.SET_ALARM -p $POA -f 0x10000000 --el time "$t" >/dev/null 2>&1
    echo "$t" > "$STATE"
    log "set  $t ($(date -d @"${t%???}" '+%a %m-%d %H:%M')) slot=$(current_slot) [$1]"
  else
    # Only clear the RTC slot if it still holds the alarm we put there, so a
    # power-off alarm armed by the stock clock is left alone.
    last=$(cat "$STATE" 2>/dev/null)
    slot=$(current_slot)
    if [ -n "$last" ] && [ -n "$slot" ] && [ "$slot" != 0 ] \
       && [ "${slot%???}" -eq "$(( ${last%???} - LEAD_MS / 1000 ))" ]; then
      am broadcast -a $ACT.CANCEL_ALARM -p $POA -f 0x10000000 --el time "$last" >/dev/null 2>&1
      log "cancel (no DeskClock alarm pending) [$1]"
    else
      log "no DeskClock alarm pending, slot=$slot left as is [$1]"
    fi
    rm -f "$STATE"
  fi
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 10
log "started"
sync_alarm boot

while true; do
  logcat -b system -v brief -T 1 'BroadcastQueue:W' '*:S' 2>/dev/null \
    | while read -r line; do
        case "$line" in
          *"Permission Denial"*"$ACT."*"from $PKG "*)
            sleep 2   # let DeskClock finish rescheduling in AlarmManager
            sync_alarm denial
            ;;
        esac
      done
  log "logcat exited, restarting"
  sleep 5
done
