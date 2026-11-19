# Install hook, sourced by the Magisk / KernelSU / APatch module installer.

POA=com.qualcomm.qti.poweroffalarm
PKG=com.best.deskclock

ui_print "- Qualcomm alarm relay"

# pm only exists when installing from the root manager app, not from recovery
if command -v pm >/dev/null 2>&1; then
  pm path "$POA" >/dev/null 2>&1 \
    || abort "! $POA not found: this device has no Qualcomm power-off alarm"
  pm path "$PKG" >/dev/null 2>&1 \
    || ui_print "! $PKG is not installed; the relay idles until it is"
fi

set_perm "$MODPATH/service.sh" 0 0 0755
