#!/bin/bash
# Install SISO Voice as its own app: /Applications/SISO Voice.app, started at
# login by the LaunchAgent com.siso.voice. Builds first unless --no-build.
# Refuses to swap while a dictation is recording. SISO Internal still embeds an
# older copy; the standalone app retires that runtime on launch.
set -euo pipefail
cd "$(dirname "$0")"

BUILT="build/SISO Voice.app"
DEST="/Applications/SISO Voice.app"
LABEL="com.siso.voice"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RECORDING_FLAG="$HOME/Library/Application Support/SISO Voice/is-recording"
DOMAIN="gui/$(id -u)"

[ "${1:-}" = "--no-build" ] || ./build-siso.sh
codesign --verify --strict "$BUILT"

if [ -f "$RECORDING_FLAG" ]; then
  echo "SISO Voice is recording; stop dictation before installing." >&2
  exit 1
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$DEST/Contents/MacOS/SISO Voice</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -x "SISO Voice" >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
launchctl bootstrap "$DOMAIN" "$PLIST"

for _ in $(seq 1 50); do
  if pgrep -f "$DEST/Contents/MacOS/SISO Voice" >/dev/null; then
    echo "SISO Voice running from $DEST"
    exit 0
  fi
  sleep 0.1
done
echo "SISO Voice did not start" >&2
exit 1
