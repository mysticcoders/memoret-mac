# Memoret for Mac

The menu-bar **receiver** for [Memoret](https://memoret.app). Memoret records and transcribes voice notes on iPhone and Apple Watch, seals each one to your receiver's public key, and delivers it over your local network. This app is one such receiver: it holds the private key, listens on the LAN, decrypts arriving captures, and writes them into a folder you choose.

The private key never leaves this machine. Captures are sealed with libsodium `crypto_box_seal` (X25519 + XSalsa20-Poly1305) on the phone and can only be opened here.

## Install

Download the latest signed and notarized `Memoret-<version>.dmg` from [Releases](https://github.com/mysticcoders/memoret-mac/releases/latest), open it, and drag Memoret to Applications. macOS 14 or newer.

The app is distributed outside the Mac App Store as a Developer ID build with the hardened runtime, notarized and stapled by Apple, so it opens without a Gatekeeper warning.

## Use

1. Launch Memoret. It appears in the menu bar and starts listening immediately.
2. Choose where notes are saved — any folder, including an Obsidian vault or iCloud Drive. The default is `~/Documents/Memoret`.
3. Open the pairing QR code from the menu and scan it in the iOS app under **Settings → Add receiver**.

Notes arrive as Markdown with the audio attached. Captures that cannot be delivered wait on the phone and retry when the receiver is reachable again.

## Where things live

- Configuration and the private key are in `~/Library/Application Support/Memoret/config.json`, created with owner-only permissions and never written at looser permissions at any point.
- Sealed blobs land in an inbox first, so an interrupted ingest can be resumed; blobs that fail to open are quarantined rather than dropped.
- The receiver advertises itself on the local network over mDNS/Bonjour and is never exposed to the internet.

## Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd Memoret && xcodegen generate
xcodebuild -project MemoretMac.xcodeproj -scheme Memoret -configuration Debug build
```

To produce a signed, notarized, stapled DMG you need a "Developer ID Application" certificate and a notarytool credential profile — both documented at the top of [`package.sh`](package.sh):

```bash
./package.sh                        # signed + notarized + stapled DMG
MEMORET_SKIP_NOTARIZE=1 ./package.sh  # signed only, skips notarization
```

## Other receivers

- [memoret-obsidian](https://github.com/mysticcoders/memoret-obsidian) — delivers into an Obsidian vault
- [memoret-cli](https://github.com/mysticcoders/memoret-cli) — terminal receiver for macOS, Linux, and Windows
- The delivery protocol is documented at [developer.memoret.app](https://developer.memoret.app), so you can write your own.

## License

[MIT](LICENSE)
