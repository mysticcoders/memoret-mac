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
        let notePath = try resolveDestination(
            manifest.vault_note_path, captureId: manifest.capture_id, root: vaultRoot)
        // A link capture has no recording, so there is no attachment to place
        // and no attachments directory worth creating.
        var audioPath: String?
        if pkg.audio != nil, let attachment = manifest.attachment_path {
            audioPath = try resolveDestination(
                attachment, captureId: manifest.capture_id, root: vaultRoot)
        }
        var directories = Set([parentDir(notePath)])
        if let audioPath { directories.insert(parentDir(audioPath)) }
        for relative in directories where !relative.isEmpty {
            try fm.createDirectory(
                at: vaultRoot.appendingPathComponent(relative), withIntermediateDirectories: true)
        }

        // Audio lands before the note, so a failure between them would leave
        // a recording nothing refers to — and the redelivery would resolve
        // around that orphan into a collision name rather than replacing it.
        var written: [URL] = []
        do {
            if let audio = pkg.audio, let audioPath {
                let destination = vaultRoot.appendingPathComponent(audioPath)
                try audio.write(to: destination)
                written.append(destination)
            }
            // The embed the sender wrote names its own manifest path, which
            // is only where the audio ends up when nothing renamed it.
            // Written after the destination is settled, never before.
            var transcript = pkg.transcript
            if let audioPath, let attachment = manifest.attachment_path {
                transcript = rewriteAudioEmbed(transcript, from: attachment, to: audioPath)
            }
            let destination = vaultRoot.appendingPathComponent(notePath)
            try Data(transcript.utf8).write(to: destination)
            written.append(destination)
        } catch {
            discard(written)
            throw error
        }
        return IngestResult(
            captureId: manifest.capture_id,
            duplicate: false,
            notePath: notePath,
            audioPath: audioPath
        )
    }

    /**
     Removes what a failed ingest managed to write, so a retry starts from
     an empty vault rather than around its own leftovers.

     Failures here are ignored: the caller is already unwinding with the
     error that matters, and replacing it with a cleanup error would hide
     the reason the capture failed.
     */
    static func discard(_ written: [URL]) {
        for url in written {
            try? FileManager.default.removeItem(at: url)
        }
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
     Appends a suffix before the extension so a colliding delivery never
     overwrites an existing vault file.
     */
    private static func suffixPath(_ path: String, suffix: String) -> String {
        guard let idx = path.lastIndex(of: ".") else { return "\(path)-\(suffix)" }
        return "\(path[path.startIndex..<idx])-\(suffix)\(path[idx...])"
    }

    /**
     How many suffixed names to try before giving up. Reaching this means
     something is wrong with the vault rather than with the capture, and
     failing loudly beats spinning forever.
     */
    private static let maxCollisionAttempts = 1000

    /**
     Picks a destination nothing already occupies.

     The first fallback carries the whole capture id, not a prefix of it:
     needing a fallback at all means two captures already want one name, and
     truncating the id is what makes a second clash likelier. The counter
     after it guarantees the search ends. The previous version returned its
     single alternate unchecked, and `Data.write(to:)` overwrites, so a
     second collision destroyed a capture that had already arrived.
     */
    static func resolveDestination(_ path: String, captureId: String, root: URL) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.appendingPathComponent(path).path) {
            return path
        }
        let withId = suffixPath(path, suffix: captureId)
        if !fm.fileExists(atPath: root.appendingPathComponent(withId).path) {
            return withId
        }
        for n in 2..<maxCollisionAttempts {
            let candidate = suffixPath(path, suffix: "\(captureId)-\(n)")
            if !fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        throw IngestError.noFreeDestination(path)
    }

    /**
     Points the note's audio embed at where the attachment actually landed.

     The sender writes the embed from its own manifest path, but a collision
     can rename the file underneath it, leaving the note linking to
     something that is not there.

     The whole line is matched rather than the path alone, so a transcript
     that quotes the same text is left intact, and only the first such line
     is rewritten — the contract emits exactly one, immediately after the
     frontmatter.
     */
    static func rewriteAudioEmbed(_ transcript: String, from: String, to: String) -> String {
        guard from != to else { return transcript }
        var lines = transcript.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: "![[\(from)]]") else { return transcript }
        lines[index] = "![[\(to)]]"
        return lines.joined(separator: "\n")
    }
}

enum IngestError: LocalizedError {
    case noFreeDestination(String)

    var errorDescription: String? {
        switch self {
        case .noFreeDestination(let path):
            return "no free destination for \(path)"
        }
    }
}
