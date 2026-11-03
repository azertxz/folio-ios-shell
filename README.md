# Folio iPhone shell

This repository contains the native iPhone shell and its build definition. The app downloads the owner's Folio assets from their PC over a paired, private Tailscale HTTPS connection, checks every file hash and keeps a complete offline copy on the phone. Decks and learning history are transferred directly between the owner's devices.

Use the manual Build Folio IPA workflow, or run bash build-ios.sh on a Mac with Xcode. The result is build/Folio-unsigned.ipa. Open it in Sideloadly on Windows, attach the iPhone by USB and let Sideloadly sign it with the owner's Apple account. Account credentials belong in Sideloadly's own interface.

The app's stable loopback origin hosts the existing Folio frontend and IndexedDB data. Its server binds only to 127.0.0.1 on the phone. API calls are forwarded over validated HTTPS to the paired PC. The public source includes code and icons. Private decks are obtained after installation, directly from the PC.

Keep the bundle ID app.folio.revision unchanged when refreshing the signature so the installed app's container can be preserved. Export learning data before uninstalling. The desktop app and Tailscale must be running for initial setup and sync. Offline study is available after the asset download completes.

## Refresh the temporary signature

Keep the original Folio-unsigned.ipa. In Sideloadly, use the same Apple account and bundle identifier every time. Install over the existing Folio app, preserving its container. Export your revision data before intentionally uninstalling.

Sideloadly's automatic-refresh option can re-sign the installed app before its free-account signature expires after seven days. First install by USB. Subsequent wireless refresh depends on the phone remaining paired and reachable on the same network and Sideloadly's daemon running on the PC. Manual USB re-signing with the same saved IPA remains available.
