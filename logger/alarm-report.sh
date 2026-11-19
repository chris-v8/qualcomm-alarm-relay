#!/bin/sh
# Summarises the logger's daily files: one line per alarm that rang.
#
#   logger/alarm-report.sh [DAYS]        phone via adb (needs root), default 7 days
#   logger/alarm-report.sh -f FILE...    offline, from pulled YYYY-MM-DD.log files
#
# Needs adb (online mode) and GNU awk (gawk; Git Bash and most Linux distros have it).
# Set ANDROID_SERIAL to pick a device when several are connected.

set -eu
LOGDIR=/data/adb/qualcomm_alarm_relay_logs
RELAY_LOG=/data/adb/modules/qualcomm_alarm_relay/relay.log
LATE_S=30                       # flag alarms that rang later than this
export MSYS_NO_PATHCONV=1       # Git Bash: don't rewrite the Android paths below

AWK=$(command -v gawk || command -v awk)

if [ "${1:-}" = "-f" ]; then
  shift
  input() { cat "$@"; }
else
  DAYS=${1:-7}
  input() {
    adb exec-out "su -c 'cd $LOGDIR && cat \$(ls *.log | tail -n $DAYS)'"
    adb exec-out "su -c 'cat $RELAY_LOG 2>/dev/null'" | sed 's/^/RELAY /'
  }
fi

input "$@" | tr -d '\r' | "$AWK" -v late="$LATE_S" '
function ts(d, t,    a, b) {          # "2026-11-20", "06:40:00.123" -> epoch seconds
  split(d, a, "-"); split(t, b, /[:.]/)
  return mktime(a[1] " " a[2] " " a[3] " " b[1] " " b[2] " " b[3]) + (b[4] ? b[4] / 1000 : 0)
}
function dozing(t) {                  # Doze state just before t (screen-on at the alarm ends it)
  ls = (light_t > t - 1.5) ? light_prev : light
  ds = (deep_t > t - 1.5) ? deep_prev : deep
  return (ls == 4 || ls == 5 || ls == 6 || ds == 5 || ds == 6)
}
BEGIN { light = deep = light_prev = deep_prev = 0; booted = 0 }

/^RELAY / {                           # relay.log: "MM-DD HH:MM:SS message"
  if ($4 == "ERROR:") relay_err[$2] = relay_err[$2] " " $3
  next
}
$3 == "BOOT" {                        # "YYYY-MM-DD HH:MM:SS BOOT startupmode=rtc reason=..."
  boot_t = ts($1, $2); booted = 1; unlocked = 0
  mode = $4; sub(/^startupmode=/, "", mode)
  light = deep = light_prev = deep_prev = 0
  days[substr($1, 6)] = 1
  next
}
{
  t = ts($1, $2); days[substr($1, 6)] = 1
}
/uc_finish_user_unlocked:/ { unlocked = 1; next }
/ device_idle_light: \[/ { match($0, /\[([0-9]+)/, m); light_prev = light; light = m[1]; light_t = t; next }
/ device_idle: \[/       { match($0, /\[([0-9]+)/, m); deep_prev = deep;  deep = m[1];  deep_t = t;  next }
/freeze uid: .*com\.best\.deskclock/ && !/unfreeze/ { frozen[substr($1, 6)]++; next }

/ Clock +: / {
  if (match($0, /Scheduling state change 3 to instance ([0-9]+) at ([0-9]+)\/([0-9]+)\/([0-9]+) ([0-9:]+)/, m))
    sched[m[1]] = ts(m[4] "-" m[2] "-" m[3], m[5])
  else if (match($0, /Setting fire state to instance ([0-9]+)/, m)) {
    n = ++rows; ringing[m[1]] = n
    r_t[n] = t; r_s[n] = (m[1] in sched) ? sched[m[1]] : ""
    r_state[n] = (booted ? (unlocked ? "unlocked" : "locked") : "?") (dozing(t) ? ", Doze" : "")
    r_by[n] = (booted && t - boot_t < 900) ? mode : "-"
    r_out[n] = "-"
  }
  else if (match($0, /(Setting dismissed state to|Deleting) instance ([0-9]+)/, m)) {
    if ((m[2] in ringing) && r_out[ringing[m[2]]] == "-") r_out[ringing[m[2]]] = "dismissed"
  }
  else if (match($0, /Setting snoozed state to instance ([0-9]+)/, m)) {
    if ((m[1] in ringing) && r_out[ringing[m[1]]] == "-") r_out[ringing[m[1]]] = "snoozed"
  }
  else if (match($0, /Setting missed state to instance ([0-9]+)/, m)) {
    if ((m[1] in ringing) && r_out[ringing[m[1]]] == "-") { r_out[ringing[m[1]]] = "rang unattended"; delete ringing[m[1]] }
    else if (booted && t - boot_t < 180) {          # missed while the phone was off
      n = ++rows; r_t[n] = t; r_s[n] = (m[1] in sched) ? sched[m[1]] : ""
      r_missed[n] = 1; r_state[n] = "phone was off"; r_by[n] = mode; r_out[n] = "MISSED"
    }
  }
}

END {
  for (n = 1; n <= rows; n++) {
    if (r_missed[n]) { missed++; continue }
    if (r_s[n] != "" && r_t[n] - r_s[n] > late) nlate++
  }
  for (d in days) { if (d in relay_err) nerr += split(relay_err[d], x, " "); nfrozen += frozen[d] }
  first = "9"; last = ""; for (d in days) { if (d < first) first = d; if (d > last) last = d }
  printf "Alarms %s … %s    late (>%ds): %d   missed while off: %d   relay errors: %d   deskclock frozen by ColorOS: %d\n\n",
    first, last, late, nlate, missed, nerr, nfrozen
  printf "%-10s %-8s %-8s %8s  %-18s %-11s %s\n", "Date", "Alarm", "Rang", "Delay", "Phone", "Started by", "Ended"
  for (n = 1; n <= rows; n++) {
    alarm = r_s[n] != "" ? strftime("%H:%M:%S", r_s[n]) : "?"
    if (r_missed[n]) { rang = "-"; delay = "-" }
    else {
      rang = strftime("%H:%M:%S", r_t[n])
      delay = r_s[n] != "" ? sprintf("%+d s", r_t[n] - r_s[n]) : "?"
    }
    flag = (r_missed[n] || (r_s[n] != "" && r_t[n] - r_s[n] > late)) ? "  <<" : ""
    printf "%-10s %-8s %-8s %8s  %-18s %-11s %s%s\n", strftime("%a %m-%d", r_t[n]), alarm, rang, delay, r_state[n], r_by[n], r_out[n], flag
  }
  if (!rows) print "(no alarms rang in these logs)"
  for (d in relay_err) if (d in days) print "\nrelay ERROR on " d " at" relay_err[d] " (see relay.log)"
}'
