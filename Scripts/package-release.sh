#!/bin/bash
set -euo pipefail

fail() { echo "Release packaging failed: $1" >&2; exit 1; }

for variable in RUNNER_TEMP RELEASE_TAG SIGNING_IDENTITY APPLE_TEAM_ID P12_BASE64 P12_PASSWORD \
  API_KEY_BASE64 API_KEY_ID API_ISSUER_ID; do
  [[ -n ${!variable:-} ]] || fail "Missing $variable."
done
[[ $SIGNING_IDENTITY == 'Developer ID Application:'* ]] || fail "Expected a Developer ID Application identity."
[[ $API_KEY_ID =~ ^[A-Z0-9]+$ ]] || fail "Invalid App Store Connect key ID."

archive=$1
distribution=$2
app="$archive/Products/Applications/Agents App.app"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist") == tools.agents.app ]] ||
  fail "Unexpected archived bundle identifier."
[[ v$version == "$RELEASE_TAG" ]] || fail "Archive version differs from the approved tag."
binary="$app/Contents/MacOS/$executable"
xcrun lipo -verify_arch arm64 x86_64 "$binary"
[[ $(xcrun lipo -archs "$binary" | wc -w | tr -d ' ') == 2 ]] || fail "Expected exactly two architectures."

umask 077
work=$(mktemp -d "$RUNNER_TEMP/agents-release.XXXXXX")
keychain="$work/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
certificate="$work/developer-id.p12"
api_key="$work/AuthKey_${API_KEY_ID}.p8"
printf '%s' "$P12_BASE64" | /usr/bin/base64 -D >"$certificate"
printf '%s' "$API_KEY_BASE64" | /usr/bin/base64 -D >"$api_key"
keychain_password=$(/usr/bin/openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -P "$P12_PASSWORD" -T /usr/bin/codesign -f pkcs12 -k "$keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -F "\"$SIGNING_IDENTITY\""
rm "$certificate"
unset P12_BASE64 P12_PASSWORD API_KEY_BASE64 keychain_password

/usr/bin/codesign --force --keychain "$keychain" --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$app"
/usr/bin/codesign --verify --all-architectures --deep --strict "$app"
signature=$(/usr/bin/codesign -dvvv "$app" 2>&1)
grep -Fx "TeamIdentifier=$APPLE_TEAM_ID" <<<"$signature"
grep -Fx "Authority=$SIGNING_IDENTITY" <<<"$signature"
grep -E '^Timestamp=' <<<"$signature"

submission="$work/submission.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$submission"
status=$(xcrun notarytool submit "$submission" --key "$api_key" --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER_ID" --wait --timeout 45m --output-format json)
jq -e '.status == "Accepted"' <<<"$status" >/dev/null || {
  jq -r '"Notarization submission \(.id): \(.status)"' <<<"$status" >&2
  exit 1
}
rm "$api_key"
xcrun stapler staple "$app"

mkdir "$distribution"
zip="Agents-App-$version-universal.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$distribution/$zip"
verify="$work/verify"
/usr/bin/ditto -x -k "$distribution/$zip" "$verify"
verified_app="$verify/Agents App.app"
/usr/bin/codesign --verify --all-architectures --deep --strict "$verified_app"
xcrun stapler validate "$verified_app"
spctl --assess --type execute --verbose=2 "$verified_app"
(
  cd "$distribution"
  shasum -a 256 "$zip" > "$zip.sha256"
  shasum -a 256 -c "$zip.sha256"
)
