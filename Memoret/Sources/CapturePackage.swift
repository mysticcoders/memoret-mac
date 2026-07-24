import Foundation
import ZIPFoundation

enum PackageError: LocalizedError {
    case missingEntry(String)
    case entryTooLarge(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingEntry(let name): return "package: missing entry \(name)"
        case .entryTooLarge(let name): return "package: entry \(name) exceeds size limit"
        case .unreadable: return "package: not a readable zip archive"
        }
    }
}

struct CapturePackage {
    static let audioEntry = "audio.m4a"
    static let transcriptEntry = "transcript.md"
    static let manifestEntry = "manifest.json"

    /// Per-entry uncompressed size ceilings. The 64 MB body cap bounds only
    /// the sealed (compressed) blob; without these, a decrypted entry could
    /// inflate to gigabytes and exhaust memory (a zip bomb).
    static let maxEntryBytes: [String: Int] = [
        manifestEntry: 1 * 1024 * 1024,
        transcriptEntry: 10 * 1024 * 1024,
        audioEntry: 128 * 1024 * 1024,
    ]

    let manifest: Manifest
    let transcript: String
    let audio: Data

    /**
     Parses and validates a plaintext zip package (manifest.json +
     transcript.md + audio.m4a), throwing if an entry is missing or the
     manifest is invalid. Mirrors the contract's parsePackage.
     */
    static func parse(_ zipBytes: Data) throws -> CapturePackage {
        let archive: Archive
        do {
            archive = try Archive(data: zipBytes, accessMode: .read)
        } catch {
            throw PackageError.unreadable
        }
        let manifestData = try extract(archive, entry: manifestEntry)
        let transcriptData = try extract(archive, entry: transcriptEntry)
        let audioData = try extract(archive, entry: audioEntry)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        try manifest.validate()
        return CapturePackage(
            manifest: manifest,
            transcript: String(decoding: transcriptData, as: UTF8.self),
            audio: audioData
        )
    }

    /**
     Extracts a single named entry from an in-memory archive into Data.
     */
    private static func extract(_ archive: Archive, entry name: String) throws -> Data {
        guard let entry = archive[name] else {
            throw PackageError.missingEntry(name)
        }
        let limit = maxEntryBytes[name] ?? 0
        if Int(clamping: entry.uncompressedSize) > limit {
            throw PackageError.entryTooLarge(name)
        }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
            if data.count > limit {
                throw PackageError.entryTooLarge(name)
            }
        })
        return data
    }
}
