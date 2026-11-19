# qualcomm-alarm-relay

Root module that lets [Clock](https://github.com/BlackyHawky/Clock) (`com.best.deskclock`) power the phone on for alarms on ColorOS, the way the stock clock does.

## Why

Qualcomm devices can switch themselves on for an alarm: before shutdown, the next alarm time is written into the RTC of the power-management chip, which powers the phone on when it is reached. Apps request this from Qualcomm's `com.qualcomm.qti.poweroffalarm` with a `SET_ALARM` / `CANCEL_ALARM` broadcast, and Clock does.

ColorOS guards that receiver with the signature permission `oplus.permission.OPLUS_COMPONENT_SAFE`, which only OPPO-signed apps hold, so Clock's requests are denied:

```
Permission Denial: broadcasting Intent { act=org.codeaurora.poweroffalarm.action.SET_ALARM ... }
from com.best.deskclock ... requires oplus.permission.OPLUS_COMPONENT_SAFE
```

The relay watches for these denials and sends the request itself, as root, with Clock's next alarm time.

## Requirements

- Qualcomm device with `com.qualcomm.qti.poweroffalarm` (the installer aborts without it; installed from recovery, the relay logs it and doesn't start)
- Root with module support: Magisk, KernelSU or APatch
- Clock (`com.best.deskclock`) with its power-off alarm permission granted
- Tested on: Realme GT Master Edition (RMX3363), Android 12, ColorOS 12, APatch

## Install

Download `qualcomm-alarm-relay-<version>.zip` from the releases, install it from your root manager app and reboot.

The relay logs what it does to `/data/adb/modules/qualcomm_alarm_relay/relay.log`.

## How it works

- **DeskClock's denied broadcasts** (main path): on `SET_ALARM` it reads Clock's next alarm and arms the RTC through Qualcomm's receiver; on `CANCEL_ALARM` it arms the next remaining alarm, or clears the RTC if there is none and the RTC still holds the alarm the relay put there.
- **Next alarm:** the alarm clock Clock registered with `AlarmManager` (`dumpsys alarm`, `indicator` entry); while the phone is locked after a reboot and nothing is registered, Clock's own alarm instances (its content provider, readable before the first unlock).
- **Safety nets:** after boot (for 5 minutes), when shutdown starts, and every 30 minutes, it re-arms the RTC if it doesn't hold Clock's next alarm. These never clear it.
- If Clock asks to set an alarm but its time can't be read, it posts a notification instead of failing silently.

Qualcomm's receiver arms the RTC 90 seconds before the alarm, so the phone has time to boot.

## Limits

- **Last two minutes:** the RTC can't be set less than about a minute ahead. Powering off within the last two minutes before an alarm, or after the power-off alarm started the phone but before it rang, means the phone stays off for it.
- **One slot:** the RTC holds one alarm. The stock ColorOS clock writes to the same slot, so don't keep alarms in both apps.
- **One app:** the relay serves `com.best.deskclock` (`PKG` in `relay/service.sh`).
- **Battery:** a flat battery powers on for nothing.

## Clock tips for ColorOS

- **Use a Clock version with the Direct Boot fix** ([#775](https://github.com/BlackyHawky/Clock/issues/775), commit [f75a59f](https://github.com/BlackyHawky/Clock/commit/f75a59f44e46b84bbe85b239e9f4929f21b53371), after 2.35). Older versions don't register the next alarm until the first unlock after a reboot. The relay works around the power-off part of that, but alarms can still be held back while the phone is locked.
- **Turn on "Display a foreground notification"** in Clock's settings. ColorOS freezes background apps about 30 seconds after the screen turns off (`OplusHansManager ... freeze ... com.best.deskclock ... scene: LcdOff`); an app with a foreground service is left alone.

## Logger (optional)

`qualcomm-alarm-relay-logger-<version>.zip` is a separate module that keeps a daily log of alarm-related events, to check that alarms ring on time. Disable it in the root manager to stop logging.

- Files: `/data/adb/qualcomm_alarm_relay_logs/YYYY-MM-DD.log`, kept 14 days
- Contents: a `BOOT` line per boot (`startupmode=rtc` means the power-off alarm started the phone), Clock's own log, PowerOffAlarm and ColorOS's denials, Doze, screen on/off, first unlock, shutdown, and kills, freezes and audio focus that concern Clock

Summarise them on a PC with the phone connected over adb (Git Bash on Windows):

```
logger/alarm-report.sh        # last 7 days
logger/alarm-report.sh 14     # last 14 days
logger/alarm-report.sh -f 2026-11-20.log relay.log    # pulled files
```

```
Alarms 11-19 … 11-19    late (>30s): 1   missed while off: 0   relay errors: 0   deskclock frozen by ColorOS: 1

Date       Alarm    Rang        Delay  Phone              Started by  Ended
Thu 11-19  06:40:00 06:40:00     +0 s  locked             rtc         dismissed
Thu 11-19  06:55:00 06:58:46   +226 s  locked, Doze       -           rang unattended  <<
Thu 11-19  07:10:00 07:10:01     +1 s  locked             -           dismissed
```

Needs `adb`, root on the phone, and GNU awk (`gawk`).

## Build

```
./build.sh
```

Writes `dist/qualcomm-alarm-relay-<version>.zip` and `dist/qualcomm-alarm-relay-logger-<version>.zip`, using `zip` if available, otherwise Python.

## Uninstall

Remove the modules in the root manager and reboot. The logger's files stay in `/data/adb/qualcomm_alarm_relay_logs` until deleted.
