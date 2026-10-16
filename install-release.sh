#!/bin/bash
# Install a published, notarized app without a compiler or local signing certificate.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
repo=siso-os/siso-voice
base="${SISO_VOICE_INSTALL_DIR:-$HOME/Applications}"
dest="$base/SISO Voice.app"
state="$HOME/Library/Application Support/SISO Voice"
[[ ! -f "$state/is-recording" ]] || { echo "Finish the current dictation before installing." >&2; exit 3; }
work=$(mktemp -d "${TMPDIR%/}/.siso-ephemeral-voice-install.XXXXXX")
trap 'if [[ -n "${work:-}" && "$work" == */.siso-ephemeral-voice-install.* ]]; then /bin/rm -r "$work"; fi' EXIT
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "https://api.github.com/repos/$repo/releases/latest" -o "$work/release.json"
tag=$(/usr/bin/plutil -extract tag_name raw -o - "$work/release.json")
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "The release version is invalid." >&2; exit 1; }
asset=SISO-Voice-macos-universal.zip
url="https://github.com/$repo/releases/download/$tag"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$url/$asset" -o "$work/$asset"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$url/SHA256SUMS" -o "$work/SHA256SUMS"
expected=$(awk -v asset="$asset" '$2 == asset && $1 ~ /^[a-f0-9]+$/ {print $1}' "$work/SHA256SUMS")
[[ ${#expected} == 64 && "$expected" != *$'\n'* ]] || { echo "A unique release checksum is required." >&2; exit 1; }
actual=$(/usr/bin/shasum -a 256 "$work/$asset"); actual=${actual%% *}
[[ "$actual" == "$expected" ]] || { echo "The download checksum does not match; nothing was installed." >&2; exit 1; }
# Refuse paths outside the expected app before extracting a release archive.
/usr/bin/unzip -Z1 "$work/$asset" > "$work/entries"
while IFS= read -r item; do
  [[ "$item" == "SISO Voice.app/"* && "$item" != *"../"* && "$item" != *\\* ]] || { echo "The release archive contains an unexpected path." >&2; exit 1; }
done < "$work/entries"
/usr/bin/zipinfo -l "$work/$asset" | awk 'substr($1,1,1) == "l" { exit 1 }' || { echo "Release archives may not contain symbolic links." >&2; exit 1; }
/usr/bin/ditto -x -k "$work/$asset" "$work/unpacked"
app="$work/unpacked/SISO Voice.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.siso.voice ]] || { echo "Unexpected app identity." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "${tag#v}" ]] || { echo "App and release versions do not match." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
/usr/sbin/spctl --assess --type execute "$app"
/usr/bin/xcrun stapler validate "$app"
[[ ! -f "$state/is-recording" ]] || { echo "Dictation started during download; nothing was replaced." >&2; exit 3; }
# A running copy must close normally so audio and history finish saving.
if /usr/bin/pgrep -x 'SISO Voice' >/dev/null; then echo "Quit SISO Voice and rerun the installer; the checked download was not installed." >&2; exit 3; fi
mkdir -p "$base" "$state/_archive/apps"
if [[ -e "$dest" ]]; then
  [[ -d "$dest" && ! -L "$dest" ]] || { echo "The install target is not an ordinary app bundle." >&2; exit 1; }
  mv "$dest" "$state/_archive/apps/SISO Voice-$(date +%Y%m%dT%H%M%S).app"
fi
/usr/bin/ditto "$app" "$dest"
/usr/bin/codesign --verify --deep --strict "$dest"
echo "Installed $tag at $dest. Open the app to set your own provider key and macOS permissions."
