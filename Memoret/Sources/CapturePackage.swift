import Foundation
import ZIPFoundation

enum PackageError: LocalizedError {
    case missingEntry(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingEntry(let name): return "package: missing entry \(name)"
        case .unreadable: return "package: not a readable zip archive"
        }
    }
}

struct CapturePackage {
    static let audioEntry = "audio.m4a"
    static let transcriptEntry = "transcript.md"
    static let manifestEntry = "manifest.json"

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
        var data = Data()
        _ = try archive.extract(entry, consumer: { data.append($0) })
        return data
    }
}
