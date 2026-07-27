import Foundation

enum ManifestError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "manifest: \(detail)"
        }
    }
}

/**
 What a capture carries. "voice" is a recording with audio; "link" is a URL
 shared from elsewhere and has no audio of its own.
 */
enum CaptureKind: String, Codable, CaseIterable {
    case voice
    case link
}

struct Manifest: Codable {
    static let currentVersion = 1

    let version: Int
    let capture_id: String
    let created_at: String
    let device_id: String
    let vault_note_path: String
    let tags: [String]

    /// Absent means voice, so captures written before this field existed
    /// stay valid. That is also why the version stays at 1: bumping it
    /// would make this receiver reject voice captures it handles fine.
    let kind: CaptureKind?
    /// Present for voice captures, absent for link captures.
    let attachment_path: String?
    /// Present for voice captures, absent for link captures.
    let duration_seconds: Double?
    /// Present for voice captures, absent for link captures.
    let transcript_model: String?

    /// The kind this manifest declares, treating absence as voice.
    var captureKind: CaptureKind { kind ?? .voice }

    /**
     Rejects vault-relative paths that could escape the vault or collide
     with hidden internals, mirroring the contract's isSafeVaultPath.
     */
    static func isSafeVaultPath(_ p: String) -> Bool {
        if p.isEmpty || p.hasPrefix("/") || p.contains("\\") { return false }
        return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    /**
     Decodes a manifest, reporting which field was wrong.

     Codable's own failure is "The data couldn't be read because it isn't
     in the correct format", which names nothing — so a manifest with a
     numeric tag or an unknown kind was rejected correctly and
     unhelpfully. The decoding error already carries the coding path, so
     the field is recovered from it and reported the way every other
     violation is.
     */
    static func decode(from data: Data) throws -> Manifest {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError.invalid(describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let path: [CodingKey]
        switch error {
        case .typeMismatch(_, let context),
            .valueNotFound(_, let context),
            .keyNotFound(_, let context),
            .dataCorrupted(let context):
            path = context.codingPath
        @unknown default:
            path = []
        }
        // Index components of the path carry no name, so the nearest named
        // key is the field worth reporting.
        guard let field = path.last(where: { $0.intValue == nil })?.stringValue else {
            return "could not be read"
        }
        return "\(field) is missing or not the expected type"
    }

    /**
     Validates the decoded manifest against the same rules as the TS and
     Python receivers, throwing a descriptive error on the first violation.
     */
    func validate() throws {
        guard version == Manifest.currentVersion else {
            throw ManifestError.invalid("unsupported version \(version)")
        }
        let uuidV4 = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        guard capture_id.range(of: uuidV4, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw ManifestError.invalid("capture_id must be a UUID v4")
        }
        guard isRFC3339(created_at) else {
            throw ManifestError.invalid("created_at must be an RFC 3339 timestamp")
        }
        guard !device_id.isEmpty else {
            throw ManifestError.invalid("device_id must be a non-empty string")
        }
        guard Manifest.isSafeVaultPath(vault_note_path) else {
            throw ManifestError.invalid("vault_note_path is not a safe vault-relative path")
        }
        guard tags.allSatisfy({ !$0.isEmpty }) else {
            throw ManifestError.invalid("tags must be an array of non-empty strings")
        }

        // The audio-bearing fields travel together: a voice capture carries
        // all of them, a link capture none. A half-populated manifest would
        // leave ingest guessing whether to expect an audio entry.
        switch captureKind {
        case .voice:
            guard let attachment_path, Manifest.isSafeVaultPath(attachment_path) else {
                throw ManifestError.invalid("attachment_path is not a safe vault-relative path")
            }
            guard let duration_seconds, duration_seconds.isFinite, duration_seconds >= 0 else {
                throw ManifestError.invalid("duration_seconds must be a non-negative number")
            }
            guard let transcript_model, !transcript_model.isEmpty else {
                throw ManifestError.invalid("transcript_model must be a non-empty string")
            }
        case .link:
            guard attachment_path == nil else {
                throw ManifestError.invalid("attachment_path is not allowed on a link capture")
            }
            guard duration_seconds == nil else {
                throw ManifestError.invalid("duration_seconds is not allowed on a link capture")
            }
            guard transcript_model == nil else {
                throw ManifestError.invalid("transcript_model is not allowed on a link capture")
            }
        }
    }

    /**
     Whether a timestamp is RFC 3339: a date, a time, and an offset.

     ISO8601DateFormatter alone is not enough. It rolls February 30th
     forward into March rather than refusing it, so this receiver accepted
     a day that does not exist — found by the shared corpus at
     github.com/mysticcoders/memoret-contract-fixtures. The calendar is
     asked to validate the components instead, and it is a UTC calendar
     used purely for arithmetic: the offset can legitimately put a capture
     on a different UTC day than the one it names, so nothing is converted.
     */
    private func isRFC3339(_ s: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else { return false }
        guard let year = Int(s.prefix(4)),
              let month = Int(s.dropFirst(5).prefix(2)),
              let day = Int(s.dropFirst(8).prefix(2)),
              let hour = Int(s.dropFirst(11).prefix(2)),
              let minute = Int(s.dropFirst(14).prefix(2)),
              let second = Int(s.dropFirst(17).prefix(2))
        else { return false }
        guard hour < 24, minute < 60, second < 60 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components.isValidDate(in: calendar)
    }
}
