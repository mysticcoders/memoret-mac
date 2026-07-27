import Foundation
import Sodium
import XCTest
import ZIPFoundation

@testable import Memoret

/// The receiver's ingest core, which until now had nothing exercising it —
/// and carried the same collision and embed faults found in the Obsidian
/// and Python receivers.
final class IngestTests: XCTestCase {
    private let captureID = "11111111-2222-4333-8444-555555555555"
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoret-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Destination search

    func testCollisionSearchDoesNotStopAtTheFirstAlternate() throws {
        try write("notes/a.md", "taken")
        try write("notes/a-\(captureID).md", "also taken")

        let resolved = try Ingest.resolveDestination(
            "notes/a.md", captureId: captureID, root: vault)

        XCTAssertEqual(resolved, "notes/a-\(captureID)-2.md")
    }

    func testUncontestedPathIsUsedUnchanged() throws {
        let resolved = try Ingest.resolveDestination(
            "notes/a.md", captureId: captureID, root: vault)
        XCTAssertEqual(resolved, "notes/a.md")
    }

    // MARK: - Embed rewriting

    func testRewriteLeavesAnIdenticalLineElsewhereAlone() {
        let note = [
            "---",
            "created: 2026-07-22T14:30",
            "---",
            "![[attachments/a.m4a]]",
            "",
            "I wrote ![[attachments/a.m4a]] in my notes",
            "![[attachments/a.m4a]]",
        ].joined(separator: "\n")

        let out = Ingest.rewriteAudioEmbed(
            note, from: "attachments/a.m4a", to: "attachments/a-2.m4a"
        ).components(separatedBy: "\n")

        XCTAssertEqual(out[3], "![[attachments/a-2.m4a]]")
        XCTAssertEqual(out[5], "I wrote ![[attachments/a.m4a]] in my notes")
        XCTAssertEqual(out[6], "![[attachments/a.m4a]]")
    }

    // MARK: - Whole ingest

    func testEmbedFollowsARenamedAttachment() throws {
        let keypair = MemoretCrypto.generateKeypair()
        try write("attachments/2026-07-22-1430.m4a", "taken")

        let result = try Ingest.sealedBlob(
            sealedPackage(for: keypair),
            keypair: keypair,
            vaultRoot: vault,
            alreadyIngested: [])

        let audioPath = try XCTUnwrap(result.audioPath)
        XCTAssertNotEqual(audioPath, "attachments/2026-07-22-1430.m4a")
        let note = try String(
            contentsOf: vault.appendingPathComponent(try XCTUnwrap(result.notePath)),
            encoding: .utf8)
        XCTAssertTrue(note.contains("![[\(audioPath)]]"))
        XCTAssertFalse(note.contains("![[attachments/2026-07-22-1430.m4a]]"))
        // What was already there must survive.
        XCTAssertEqual(try read("attachments/2026-07-22-1430.m4a"), "taken")
    }

    func testEmbedUntouchedWhenTheAttachmentKeepsItsPath() throws {
        let keypair = MemoretCrypto.generateKeypair()
        let result = try Ingest.sealedBlob(
            sealedPackage(for: keypair),
            keypair: keypair,
            vaultRoot: vault,
            alreadyIngested: [])
        let note = try String(
            contentsOf: vault.appendingPathComponent(try XCTUnwrap(result.notePath)),
            encoding: .utf8)
        XCTAssertTrue(note.contains("![[attachments/2026-07-22-1430.m4a]]"))
    }

    func testFailedNoteWriteLeavesNoOrphanAudio() throws {
        let keypair = MemoretCrypto.generateKeypair()
        // A read-only notes folder fails the note write specifically, after
        // the audio has already been written. A directory in the note's
        // place would not do it: that reads as a collision, and the search
        // correctly routes around it to a free name.
        let notes = vault.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: notes.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: notes.path)
        }

        XCTAssertThrowsError(
            try Ingest.sealedBlob(
                sealedPackage(for: keypair),
                keypair: keypair,
                vaultRoot: vault,
                alreadyIngested: []))

        let orphan = vault.appendingPathComponent("attachments/2026-07-22-1430.m4a")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "the recording must not survive the note that was to refer to it")
    }

    func testDuplicateCaptureIsNotWrittenAgain() throws {
        let keypair = MemoretCrypto.generateKeypair()
        let result = try Ingest.sealedBlob(
            sealedPackage(for: keypair),
            keypair: keypair,
            vaultRoot: vault,
            alreadyIngested: [captureID])
        XCTAssertTrue(result.duplicate)
        XCTAssertNil(result.notePath)
    }

    // MARK: - Helpers

    private func write(_ relative: String, _ contents: String) throws {
        let url = vault.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: vault.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Builds the package the sender would produce, then seals it to the
    /// receiver's public key the way the iOS app does.
    private func sealedPackage(for keypair: Keypair) throws -> Data {
        let manifest: [String: Any] = [
            "version": 1,
            "capture_id": captureID,
            "created_at": "2026-07-22T14:30:00-07:00",
            "device_id": "test-device",
            "vault_note_path": "notes/2026-07-22-1430.md",
            "attachment_path": "attachments/2026-07-22-1430.m4a",
            "tags": ["voice", "capture"],
            "duration_seconds": 92,
            "transcript_model": "parakeet-v3",
        ]
        let note = [
            "---",
            "created: 2026-07-22T14:30",
            "---",
            "![[attachments/2026-07-22-1430.m4a]]",
            "",
            "a transcript",
            "",
        ].joined(separator: "\n")

        let archive = try Archive(accessMode: .create)
        try addEntry(
            archive, "manifest.json",
            try JSONSerialization.data(withJSONObject: manifest))
        try addEntry(archive, "transcript.md", Data(note.utf8))
        try addEntry(archive, "audio.m4a", Data([0x00, 0x01, 0x02]))
        let zip = try XCTUnwrap(archive.data)

        let sodium = Sodium()
        let sealed = try XCTUnwrap(
            sodium.box.seal(message: [UInt8](zip), recipientPublicKey: keypair.publicKey))
        return Data(MemoretCrypto.sealedMagic + sealed)
    }

    private func addEntry(_ archive: Archive, _ name: String, _ data: Data) throws {
        try archive.addEntry(
            with: name, type: .file, uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
    }
}
