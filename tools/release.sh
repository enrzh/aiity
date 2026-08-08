#!/usr/bin/env bash
#
# One command from a clean tree to a build sitting in App Store Connect.
#
#   tools/release.sh            # build, verify, archive, export  (no upload)
#   tools/release.sh --upload   # …and send it to App Store Connect
#
# Every check in here exists because it already went wrong once. In particular
# the SDK check: an archive built with Xcode-beta signs, exports and transfers
# perfectly, and is then rejected by Apple at ingestion with "Unsupported SDK or
# Xcode version". That round trip takes ten minutes to fail. This takes none.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${OUT:-/tmp/aiity-release}"
UPLOAD=no
[[ "${1:-}" == "--upload" ]] && UPLOAD=yes

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. toolchain -----------------------------------------------------------
# Apple accepts beta SDKs for building and refuses them for submitting.
say "Toolchain"
DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
XCODE_APP="${DEV%/Contents/Developer}"
XCODE_VER=$(defaults read "$XCODE_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
echo "    $XCODE_APP  (Xcode $XCODE_VER)"

if [[ "$XCODE_APP" == *-beta.app || "$XCODE_APP" == *beta* ]]; then
  if [[ "$UPLOAD" == yes ]]; then
    fail "refusing to upload from a beta Xcode ($XCODE_APP).
    App Store Connect rejects beta-SDK builds at ingestion, so this would
    fail after the whole archive + upload cycle. Install a release Xcode and
    point DEVELOPER_DIR at it:
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
  fi
  echo "    NOTE: beta Xcode — fine for building, cannot be uploaded."
fi

# --- 2. project -------------------------------------------------------------
# project.yml is the source of truth; a file missing from it is never compiled.
say "Regenerating the project"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"
xcodegen generate

# --- 2b. components ---------------------------------------------------------
# A fresh Xcode 26 install has neither of these, and both fail late: the iOS
# platform makes every destination ineligible (including "Any iOS Device"), and
# the missing Metal compiler surfaces as a mlx-swift shader build failure
# partway through the unit tests. Seconds here beats ten minutes there.
say "Preflight"
xcrun metal --version >/dev/null 2>&1 \
  || fail "the Metal toolchain is not installed, and mlx-swift compiles .metal
    shaders, so even the unit tests cannot build. Fix (no password needed):
      xcodebuild -downloadComponent MetalToolchain"
echo "    metal toolchain ok"

if ! xcodebuild -showdestinations -project AIApp.xcodeproj -scheme AIApp 2>/dev/null \
     | grep -q 'platform:iOS[,}]'; then
  fail "no usable iOS destination — the iOS platform is probably not installed
    for this Xcode. Fix (no password needed, ~8.5 GB):
      xcodebuild -downloadPlatform iOS"
fi
echo "    ios platform ok"

# --- 3. tests ---------------------------------------------------------------
# Check the COUNT, not the exit code: a test file absent from project.yml does
# not compile, and xcodebuild still exits 0.
say "Unit tests"
MIN_TESTS="${MIN_TESTS:-377}"
# Pick an iPhone on a runtime this Xcode can actually target: a newer
# simulator runtime than the installed SDK (e.g. an iOS 27 sim under Xcode 26)
# is listed as available but cannot be built for. Override with SIM=<udid>.
SIM="${SIM:-}"
if [[ -z "$SIM" ]]; then
  SDK_MAJOR=$(xcodebuild -showsdks 2>/dev/null | sed -n 's/.*-sdk iphonesimulator\([0-9]*\).*/\1/p' | head -1)
  SIM=$(xcrun simctl list devices available --json | SDK_MAJOR="$SDK_MAJOR" python3 -c "
import json, os, sys, re
sdk = int(os.environ.get('SDK_MAJOR') or 0)
devices = json.load(sys.stdin)['devices']
best = None
for runtime, items in devices.items():
    m = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not m: continue
    major = int(m.group(1))
    if sdk and major > sdk: continue          # runtime newer than the SDK
    for d in items:
        if 'iPhone' in d['name']:
            key = (major, int(m.group(2)))
            if best is None or key > best[0]: best = (key, d['udid'])
print(best[1] if best else '')")
fi
[[ -n "$SIM" ]] || fail "no iPhone simulator on a runtime this Xcode can target.
    Install a matching simulator runtime in Xcode > Settings > Components."
TEST_LOG="$OUT/tests.log"; mkdir -p "$OUT"
xcodebuild test -project AIApp.xcodeproj -scheme AIApp \
  -destination "id=$SIM" -only-testing:AIAppTests \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
  >"$TEST_LOG" 2>&1 || { tail -30 "$TEST_LOG"; fail "tests failed (full log: $TEST_LOG)"; }

COUNT=$(grep -oE 'Executed [0-9]+ tests' "$TEST_LOG" | tail -1 | grep -oE '[0-9]+' || echo 0)
echo "    executed $COUNT tests"
[[ "$COUNT" -ge "$MIN_TESTS" ]] || fail "only $COUNT tests ran, expected >= $MIN_TESTS.
    A test file is probably missing from project.yml, which compiles nothing
    and still exits 0. Raise MIN_TESTS deliberately when you add tests."

# --- 4. archive -------------------------------------------------------------
say "Archiving"
ARCHIVE="$OUT/aiity.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild archive -project AIApp.xcodeproj -scheme AIApp -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  >"$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; fail "archive failed"; }

APP="$ARCHIVE/Products/Applications/AIApp.app"
EXT="$APP/PlugIns/AIAppLiveActivity.appex"

# --- 5. the checks that caught real bugs ------------------------------------
say "Verifying the built bundles"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || echo "?"; }

APP_V=$(plist "$APP" CFBundleShortVersionString);  APP_B=$(plist "$APP" CFBundleVersion)
EXT_V=$(plist "$EXT" CFBundleShortVersionString);  EXT_B=$(plist "$EXT" CFBundleVersion)
echo "    app       $APP_V ($APP_B)"
echo "    extension $EXT_V ($EXT_B)"
# XcodeGen writes its own defaults (1.0/1) into any plist that does not declare
# these, which drifts from the app and is rejected as ITMS-90473. Reading
# project.yml does NOT catch it — only the built bundle does.
[[ "$APP_V" == "$EXT_V" && "$APP_B" == "$EXT_B" ]] \
  || fail "app and extension versions differ — ITMS-90473 on upload."

# A Release binary must not carry the debug seams. PROVIDER_SETTINGS_JSON once
# shipped un-gated and let anyone redirect the app's API base URL.
for seam in PROVIDER_SETTINGS_JSON AIITY_TEST_API_KEY AIITY_SET_PROVIDER AIITY_AGENTS_FILE; do
  if strings -a "$APP/AIApp" 2>/dev/null | grep -q "$seam"; then
    fail "debug seam '$seam' is present in the Release binary."
  fi
done
echo "    no debug seams"

[[ -f "$APP/PrivacyInfo.xcprivacy" ]] || fail "PrivacyInfo.xcprivacy missing (ITMS-91053)."
echo "    privacy manifest present"

# --- 6. export --------------------------------------------------------------
say "Exporting for App Store Connect"
DEST=export; [[ "$UPLOAD" == yes ]] && DEST=upload
cat >"$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>H8FW6W6K2D</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>$DEST</string>
</dict></plist>
PLIST

rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates 2>&1 | tail -5

say "Done — $APP_V ($APP_B)"
if [[ "$UPLOAD" == yes ]]; then
  echo "    uploaded; App Store Connect takes 5–30 min to process it."
else
  echo "    $OUT/export/AIApp.ipa"
  echo "    re-run with --upload to send it."
fi
