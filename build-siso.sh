#!/bin/bash
# SISO Voice mic-safe local build.
# Builds to a staging bundle, verifies stable signing, then atomically swaps the
# completed app into build/SISO Voice.app. This script never quits, pkills,
# opens, or relaunches the running orb.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"

APP_NAME="SISO Voice"
BUNDLE_ID="com.siso.voice"
IDENTITY="SISO Voice Dev Local"
ROOT_BUILD_DIR="build"
STAGING_BUILD_DIR="$ROOT_BUILD_DIR/staging/current"
STAGED_APP="$STAGING_BUILD_DIR/$APP_NAME.app"
FINAL_APP="$ROOT_BUILD_DIR/$APP_NAME.app"
PREVIOUS_DIR="$ROOT_BUILD_DIR/previous"
STAMP="$(date +%Y%m%dT%H%M%S)"
PREVIOUS_APP="$PREVIOUS_DIR/$APP_NAME.app.$STAMP"
MAKE_BIN="${MAKE:-make}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

verify_app() {
  local app="$1"
  local executable="$app/Contents/MacOS/$APP_NAME"
  local info_plist="$app/Contents/Info.plist"
  local actual_bundle_id
  local actual_executable
  local sign_info

  [ -d "$app" ] || fail "missing app bundle: $app"
  [ -f "$info_plist" ] || fail "missing Info.plist: $info_plist"
  [ -x "$executable" ] || fail "missing executable: $executable"

  actual_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")
  [ "$actual_bundle_id" = "$BUNDLE_ID" ] || fail "wrong bundle id: $actual_bundle_id"

  actual_executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist")
  [ "$actual_executable" = "$APP_NAME" ] || fail "wrong executable name: $actual_executable"

  sign_info="$(codesign -dvv "$app" 2>&1)"
  printf "%s\n" "$sign_info" | grep -q "Authority=$IDENTITY" \
    || fail "wrong signing authority for $app; expected $IDENTITY"
  if printf "%s\n" "$sign_info" | grep -q "Signature=adhoc"; then
    fail "ad-hoc signature detected on $app"
  fi

  codesign --verify --verbose=2 "$app" >/dev/null
}

atomic_swap() {
  local staged="$1"
  local final="$2"

  python3 - "$staged" "$final" <<'PY'
import ctypes
import os
import sys

staged, final = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL("libc.dylib", use_errno=True)
renamex_np = libc.renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
RENAME_SWAP = 0x00000002

if renamex_np(staged.encode(), final.encode(), RENAME_SWAP) != 0:
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err), f"{staged} <-> {final}")
PY
}

if [ "$IDENTITY" = "-" ]; then
  fail "ad-hoc signing is forbidden for SISO Voice"
fi

security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
  || fail "missing stable signing certificate \"$IDENTITY\"; refusing ad-hoc fallback"

rm -rf "$STAGING_BUILD_DIR"
mkdir -p "$STAGING_BUILD_DIR" "$PREVIOUS_DIR"

echo "Building staged $APP_NAME bundle"
"$MAKE_BIN" build-bundle \
  APP_NAME="$APP_NAME" \
  BUNDLE_ID="$BUNDLE_ID" \
  CODESIGN_IDENTITY="$IDENTITY" \
  BUILD_DIR="$STAGING_BUILD_DIR"

echo "Verifying staged bundle"
verify_app "$STAGED_APP"

mkdir -p "$ROOT_BUILD_DIR"
if [ -d "$FINAL_APP" ]; then
  echo "Atomically swapping staged bundle into $FINAL_APP"
  atomic_swap "$STAGED_APP" "$FINAL_APP"
  if [ -d "$STAGED_APP" ]; then
    mv "$STAGED_APP" "$PREVIOUS_APP" || true
  fi
else
  echo "Installing first completed bundle into $FINAL_APP"
  mv "$STAGED_APP" "$FINAL_APP"
fi

echo "Verifying final bundle"
verify_app "$FINAL_APP"

rm -rf "$STAGING_BUILD_DIR"

echo "Built $FINAL_APP with stable identity \"$IDENTITY\". Running app was not quit or relaunched."
