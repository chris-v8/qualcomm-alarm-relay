# Install hook, sourced by the Magisk / KernelSU / APatch module installer.

ui_print "- Qualcomm alarm relay logger"
ui_print "- Daily logs: /data/adb/qualcomm_alarm_relay_logs (kept 14 days)"
ui_print "- Disable this module to stop logging; the logs stay until deleted"

set_perm "$MODPATH/service.sh" 0 0 0755
