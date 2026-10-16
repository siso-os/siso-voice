#!/bin/bash
# Build a versioned universal artifact; public releases require Apple notarization.
set -euo pipefail
cd "$(dirname "$0")"
version=${1:?Usage: build-release.sh X.Y.Z}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a semantic release version." >&2; exit 1; }
candidate=${SISO_VOICE_RELEASE_CANDIDATE:-0}
if [[ "$candidate" == 1 ]]; then
  identity='SISO Voice Dev Local'
  output="build/candidates/$version"
else
  identity=${SISO_VOICE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}
  [[ "$identity" == 'Developer ID Application: '* ]] || { echo "Public releases require Developer ID Application signing." >&2; exit 1; }
  profile=${SISO_VOICE_NOTARY_PROFILE:?Set the existing notarytool keychain profile name}
  output="build/releases/$version"
fi
security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null || { echo "The configured signing identity is unavailable." >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "This version already has an artifact; use a fresh version or archive the previous candidate." >&2; exit 1; }
mkdir -p "$output/SISO Voice.app/Contents/MacOS" "$output/SISO Voice.app/Contents/Resources"
app="$output/SISO Voice.app"
sdk=$(xcrun --show-sdk-path)
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find Sources -name '*.swift' -type f | LC_ALL=C sort)
for architecture in arm64 x86_64; do
  swiftc -O -whole-module-optimization -parse-as-library -sdk "$sdk" -target "$architecture-apple-macosx13.0" "${sources[@]}" -o "$output/voice-$architecture"
done
lipo -create "$output/voice-arm64" "$output/voice-x86_64" -output "$app/Contents/MacOS/SISO Voice"
cp Info.plist "$app/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do plutil -replace "$key" -string 'SISO Voice' "$app/Contents/Info.plist"; done
plutil -replace CFBundleIdentifier -string com.siso.voice "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
timestamp=()
[[ "$candidate" == 1 ]] || timestamp=(--timestamp)
codesign --options runtime "${timestamp[@]}" --sign "$identity" --entitlements FreeFlow.entitlements "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$output/SISO-Voice-macos-universal.zip"
if [[ "$candidate" != 1 ]]; then
  xcrun notarytool submit "$output/SISO-Voice-macos-universal.zip" --keychain-profile "$profile" --wait --output-format json > "$output/notarization.json"
  [[ "$(plutil -extract status raw -o - "$output/notarization.json")" == Accepted ]] || { echo "Apple did not accept this release." >&2; exit 1; }
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
  # Include the stapled ticket in the final archive.
  mv "$output/SISO-Voice-macos-universal.zip" "$output/pre-notarization.zip"
  ditto -c -k --keepParent "$app" "$output/SISO-Voice-macos-universal.zip"
fi
(cd "$output" && shasum -a 256 SISO-Voice-macos-universal.zip > SHA256SUMS)
printf 'Built %s (%s). Candidate artifacts are local-only and cannot pass the public installer.\n' "$output" "$([[ "$candidate" == 1 ]] && echo candidate || echo notarized)"
