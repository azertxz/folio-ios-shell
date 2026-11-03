#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi
xcodegen generate --spec project.yml
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for devices in json.load(sys.stdin)["devices"].values() for d in devices if d["name"].startswith("iPhone") and d["isAvailable"]))')
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Debug -sdk iphonesimulator -destination "id=$device" -parallel-testing-enabled NO -derivedDataPath build/simulator -resultBundlePath build/Folio-UI-tests.xcresult CODE_SIGNING_ALLOWED=NO test
xcrun xcresulttool export attachments --path build/Folio-UI-tests.xcresult --output-path build/ui-test-attachments
