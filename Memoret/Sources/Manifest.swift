import Foundation

enum ManifestError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "manifest: \(detail)"
        }
    }
}

struct Manifest: Codable {
    static let currentVersion = 1

    let version: Int
    let capture_id: String
    let created_at: String
    let device_id: String
    let vault_note_path: String
    let attachment_path: String
    let tags: [String]
    let duration_seconds: Double
    let transcript_model: String

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
        guard !created_at.isEmpty, parseISODate(created_at) != nil else {
            throw ManifestError.invalid("created_at must be an ISO-8601 timestamp")
        }
        guard !device_id.isEmpty else {
            throw ManifestError.invalid("device_id must be a non-empty string")
        }
        guard Manifest.isSafeVaultPath(vault_note_path) else {
            throw ManifestError.invalid("vault_note_path is not a safe vault-relative path")
        }
        guard Manifest.isSafeVaultPath(attachment_path) else {
            throw ManifestError.invalid("attachment_path is not a safe vault-relative path")
        }
        guard tags.allSatisfy({ !$0.isEmpty }) else {
            throw ManifestError.invalid("tags must be an array of non-empty strings")
        }
        guard duration_seconds.isFinite, duration_seconds >= 0 else {
            throw ManifestError.invalid("duration_seconds must be a non-negative number")
        }
        guard !transcript_model.isEmpty else {
            throw ManifestError.invalid("transcript_model must be a non-empty string")
        }
    }

    /**
     Parses an ISO-8601 timestamp with or without fractional seconds.
     */
    private func parseISODate(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }
}
