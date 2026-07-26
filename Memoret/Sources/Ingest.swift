import Foundation

struct IngestResult {
    let captureId: String
    let duplicate: Bool
    let notePath: String?
    let audioPath: String?
}

enum Ingest {
    /**
     The receiver's ingest core: opens a sealed blob with the receiver
     keypair, validates the package, and writes the note plus audio
     attachment at their manifest paths under the vault root. Deduplicates
     by capture_id so redelivery over any transport is idempotent. Throws
     on bad crypto or an invalid package; callers decide what to do with
     the offending blob.
     */
    static func sealedBlob(
        _ blob: Data,
        keypair: Keypair,
        vaultRoot: URL,
        alreadyIngested: Set<String>
    ) throws -> IngestResult {
        let plaintext = try MemoretCrypto.openSealed([UInt8](blob), keypair: keypair)
        let pkg = try CapturePackage.parse(Data(plaintext))
        let manifest = pkg.manifest
        if alreadyIngested.contains(manifest.capture_id) {
            return IngestResult(captureId: manifest.capture_id, duplicate: true, notePath: nil, audioPath: nil)
        }
        let fm = FileManager.default
        let notePath = resolveDestination(manifest.vault_note_path, captureId: manifest.capture_id, root: vaultRoot)
        // A link capture has no recording, so there is no attachment to place
        // and no attachments directory worth creating.
        var audioPath: String?
        if let audio = pkg.audio, let attachment = manifest.attachment_path {
            audioPath = resolveDestination(attachment, captureId: manifest.capture_id, root: vaultRoot)
            var directories = Set([parentDir(notePath)])
            if let audioPath { directories.insert(parentDir(audioPath)) }
            for relative in directories where !relative.isEmpty {
                try fm.createDirectory(at: vaultRoot.appendingPathComponent(relative), withIntermediateDirectories: true)
            }
            try audio.write(to: vaultRoot.appendingPathComponent(audioPath!))
        } else if !parentDir(notePath).isEmpty {
            try fm.createDirectory(
                at: vaultRoot.appendingPathComponent(parentDir(notePath)),
                withIntermediateDirectories: true)
        }
        try Data(pkg.transcript.utf8).write(to: vaultRoot.appendingPathComponent(notePath))
        return IngestResult(
            captureId: manifest.capture_id,
            duplicate: false,
            notePath: notePath,
            audioPath: audioPath
        )
    }

    /**
     Returns the parent directory of a vault-relative path, or empty string
     for root-level paths.
     */
    private static func parentDir(_ path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<idx])
    }

    /**
     Appends a short capture-id suffix before the extension so a colliding
     delivery never overwrites an existing vault file.
     */
    private static func suffixPath(_ path: String, captureId: String) -> String {
        let short = String(captureId.prefix(8))
        guard let idx = path.lastIndex(of: ".") else { return "\(path)-\(short)" }
        return "\(path[path.startIndex..<idx])-\(short)\(path[idx...])"
    }

    /**
     Picks a collision-free destination, preferring the manifest path and
     falling back to a capture-id-suffixed variant.
     */
    private static func resolveDestination(_ path: String, captureId: String, root: URL) -> String {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            return path
        }
        return suffixPath(path, captureId: captureId)
    }
}
