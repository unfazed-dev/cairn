#!/usr/bin/env bash
# CairnSmoke — build + deploy + run the iOS-sim smoke test.
#
# Verifies the END-TO-END round-trip on the iPhone 17 simulator:
#   construct CairnClient → connect() → query(SELECT 1) → checkpoint()
#
# ponytail: debug build of the Rust staticlib is fine for a smoke (not a
# shipped binary). The harness links libcairn_swift.a DIRECTLY rather than via
# the xcframework (Tier 1 builds the xcframework separately as a deliverable).
#
# Usage: ./build.sh
# Exit codes: 0 = SUCCESS line captured on sim; non-zero = see $LOG.

set -euo pipefail

ROOT="/Volumes/developer_ssd/Developer/cairn/sdk/cairn_swift"
cd "$ROOT"

SIM_UDID="${CAIRN_SIM_UDID:-CAFC93F7-5815-4A86-B9FA-95123DE3018C}"
BUNDLE_ID="com.cairn.smoke"
LOG="/tmp/cairn_smoke_launch.log"

echo "[harness] 1/6 cargo build --target aarch64-apple-ios-sim"
cargo build --target aarch64-apple-ios-sim

echo "[harness] 2/6 xcodegen generate"
cd ios-test
xcodegen generate 2>&1 | tail -10

echo "[harness] 3/6 xcodebuild -sdk iphonesimulator -destination id=$SIM_UDID"
xcodebuild \
  -project CairnSmoke.xcodeproj \
  -scheme CairnSmoke \
  -sdk iphonesimulator \
  -destination "id=$SIM_UDID" \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build > /tmp/cairn_smoke_xcodebuild.log 2>&1 || { echo "BUILD FAILED — see /tmp/cairn_smoke_xcodebuild.log"; tail -40 /tmp/cairn_smoke_xcodebuild.log; exit 1; }

APP_PATH="build/Build/Products/Debug-iphonesimulator/CairnSmoke.app"
echo "[harness] built: $APP_PATH"

echo "[harness] 4/6 simctl uninstall (clean state)"
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "[harness] 5/6 simctl install"
xcrun simctl install "$SIM_UDID" "$APP_PATH"

echo "[harness] 6/6 simctl launch --console-pty"
# --console-pty pipes the app's stdout/stderr straight to this terminal.
rm -f "$LOG"
# Launch with output capture; foreground launch returns when the app exits.
xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID" > "$LOG" 2>&1 || true

echo "[harness] ----- captured sim stdout (raw) -----"
cat "$LOG" || echo "(no output)"
echo "[harness] ----- end -----"

if grep -q '\[cairn-smoke\] SUCCESS' "$LOG"; then
  echo "[harness] VERDICT: round-trip ran on iPhone 17 sim"
  exit 0
else
  echo "[harness] VERDICT: SUCCESS line NOT captured — see $LOG"
  exit 2
fi
