# Working in Memoret for Mac

This menu-bar app is a Memoret receiver: it holds a private key, advertises itself on the local network and accepts sealed captures (`Memoret/Sources/LanServer.swift`), opens them with CryptoKit (`Crypto.swift`), validates the manifest (`Manifest.swift`, `CapturePackage.swift`) and writes notes and audio into a folder (`Ingest.swift`). The protocol, its vocabulary and the ingest rules are on [developer.memoret.app](https://developer.memoret.app); use the terms in [its glossary](https://developer.memoret.app/#glossary).

## The contract

- This is an independent Swift implementation of the Memoret contract. It agrees with the TypeScript and Python implementations by specification and by tests, not by shared code. Keep crypto on CryptoKit; don't add third-party crypto.
- Manifest behavior is pinned by [memoret-contract-fixtures](https://github.com/mysticcoders/memoret-contract-fixtures). A disagreement with the corpus is a bug here unless the corpus is wrong, in which case it is fixed there first, tagged, and adopted by changing the tag in `scripts/fetch-fixtures.sh`.

## Rules

- The private key never leaves this Mac. Never log or persist plaintext captures, transcripts, keys or pairing tokens.
- Follow the ingest rules on the developer site for idempotency, path safety, collisions, embed rewriting, write order, cleanup on failure and quarantine. Never write outside the configured folder.

## Checks

- From the repository root: `scripts/fetch-fixtures.sh`. Then in `Memoret/`: `xcodegen generate` and `xcodebuild test -project MemoretMac.xcodeproj -scheme Memoret`. CI runs the same on pull requests and pushes to `main`.
- Tests do not verify a real phone, Bonjour on a real network, signing or notarization; say which evidence you have.

## Delivery

- Work on a branch and open a pull request with the problem, the change, how it was verified, and what remains.
- `package.sh` signs, notarizes and staples the DMG with the Developer ID certificate. Run it only when asked to release.
