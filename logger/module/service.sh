#!/system/bin/sh
# Daily log of alarm-related events, to check that alarms ring on time.
# Optional companion of qualcomm_alarm_relay; summarise the files with
# logger/alarm-report.sh on a PC.
#
#   /data/adb/qualcomm_alarm_relay_logs/YYYY-MM-DD.log, kept KEEP_DAYS days:
#   - a BOOT line per boot (startupmode=rtc means the power-off alarm started it)
#   - DeskClock's own log, Qualcomm PowerOffAlarm, ColorOS's denials of it
#   - Doze, screen on/off, first unlock, shutdown
#   - kills, freezes, alarm manager and audio focus lines that concern DeskClock

LOGDIR=/data/adb/qualcomm_alarm_relay_logs
KEEP_DAYS=14
PKG=com.best.deskclock
PIDFILE=$LOGDIR/logger.pid

mkdir -p "$LOGDIR"

# Already running? PIDs get recycled across boots, so check the command line.
if [ -f "$PIDFILE" ]; then
  tr '\0' ' ' < "/proc/$(cat "$PIDFILE")/cmdline" 2>/dev/null \
    | grep -q 'qualcomm_alarm_relay_logger/service.sh' && exit 0
fi
echo $$ > "$PIDFILE"

cleanup() {
  find "$LOGDIR" -name '*.log' -mtime +$KEEP_DAYS -delete 2>/dev/null
}

# Room for the boot burst until logcat below has read it
logcat -G 4M 2>/dev/null

mode=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^androidboot.startupmode=//p' | head -n 1)
echo "$(date '+%Y-%m-%d %H:%M:%S') BOOT startupmode=$mode reason=$(getprop sys.boot.reason)" \
  >> "$LOGDIR/$(date +%Y-%m-%d).log"

cleanup
( while sleep 21600; do cleanup; done ) &   # every 6 h of awake time

# First pass reads everything since boot; restarts only follow new lines.
read_log() {
  if [ -n "$SINCE" ]; then
    logcat -b main,system,events -v year -T "$SINCE" 'qarl_logger:S' '*:V' 2>/dev/null
  else
    logcat -b main,system,events -v year 'qarl_logger:S' '*:V' 2>/dev/null
  fi
}
SINCE=
while true; do
  read_log \
    | awk -v dir="$LOGDIR" -v pkg="$PKG" '
        / System\.err |am_pss|OplusLayer|SurfaceFlinger|BLASTBufferQueue|InputDispatcher|TileServices|PeopleSpace/ { next }
        / Clock +: | AlarmActivity: |PowerOffAlarm|Permission Denial.*poweroffalarm|device_idle(_light)?: |screen_toggled|uc_finish_user_unlocked:|ShutdownThread/ \
        || (index($0, pkg) && /am_kill|am_proc_died|am_freeze|[Ff]reeze|Hans|AlarmManager|Background started FGS|requestAudioFocus/) {
          f = dir "/" $1 ".log"   # -v year: $1 is the date of the line
          print >> f; fflush(f)
        }'
  SINCE=$(date '+%m-%d %H:%M:%S.000')
  sleep 5
done
