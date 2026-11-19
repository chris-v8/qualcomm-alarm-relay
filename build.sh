#!/bin/sh
# Builds the installable module zips into dist/:
#   qualcomm-alarm-relay-<version>.zip          from relay/
#   qualcomm-alarm-relay-logger-<version>.zip   from logger/module/
# Uses zip if available, otherwise Python's zipfile.
set -eu
cd "$(dirname "$0")"
mkdir -p dist

if command -v zip >/dev/null 2>&1; then
  pack() { (cd "$1" && zip -qr -X "$2" .); }
else
  PY=$(command -v python3 || command -v python) \
    || { echo "need zip or python" >&2; exit 1; }
  pack() {
    "$PY" - "$1" "$2" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src).replace(os.sep, "/"))
EOF
  }
fi

build() {  # $1 = module dir, $2 = zip name prefix
  [ -f "$1/module.prop" ] || return 0
  ver=$(sed -n 's/^version=//p' "$1/module.prop")
  out="$PWD/dist/$2-$ver.zip"
  rm -f "$out"
  pack "$1" "$out"
  echo "built dist/$2-$ver.zip"
}

build relay qualcomm-alarm-relay
build logger/module qualcomm-alarm-relay-logger
