#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi
xcodegen generate --spec project.yml
xcodebuild -project Folio.xcodeproj -scheme Folio -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p build/ipa/Payload
ditto build/Build/Products/Release-iphoneos/Folio.app build/ipa/Payload/Folio.app
cd build/ipa
zip -q -r ../Folio-unsigned.ipa Payload
echo "Created build/Folio-unsigned.ipa for signing in Sideloadly."
