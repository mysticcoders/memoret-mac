import Foundation
import XCTest

@testable import Memoret

/// The shared corpus this receiver is measured against.
///
/// The corpus lives in its own public repository so every implementation
/// reads one copy rather than keeping its own to drift. Fetch it with
/// `scripts/fetch-fixtures.sh`; CI does that before the suite.
///
/// A missing corpus fails loudly rather than skipping: a conformance suite
/// that quietly runs nothing is worse than none, because it reads as
/// agreement.
final class ConformanceTests: XCTestCase {
    private struct Corpus: Decodable {
        let corpusVersion: Int
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let accept: Bool
        let reason: String?
        let manifest: JSONValue
    }

    private func loadCorpus() throws -> Corpus {
        // The test bundle sits deep inside DerivedData, so the corpus is
        // found by walking up from this file rather than from the bundle.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Memoret
            .deletingLastPathComponent()  // repository root
        let path = root.appendingPathComponent("fixtures/manifests.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            XCTFail(
                "conformance corpus missing at \(path.path). "
                    + "Run scripts/fetch-fixtures.sh to download it.")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: path))
    }

    func testCorpusIsNotEmpty() throws {
        // A mis-resolved path must not pass as agreement.
        XCTAssertGreaterThan(try loadCorpus().cases.count, 10)
    }

    func testManifestsMatchTheCorpus() throws {
        let corpus = try loadCorpus()
        for testCase in corpus.cases {
            let data = try JSONSerialization.data(withJSONObject: testCase.manifest.raw)
            var failure: String?
            do {
                // The same entry point the receiver uses, so the test
                // measures what a real capture goes through.
                let manifest = try Manifest.decode(from: data)
                try manifest.validate()
            } catch {
                failure = error.localizedDescription
            }

            if testCase.accept {
                XCTAssertNil(
                    failure, "corpus case '\(testCase.name)' should be accepted")
                continue
            }
            guard let failure else {
                XCTFail("corpus case '\(testCase.name)' should be rejected")
                continue
            }
            guard let reason = testCase.reason else { continue }
            // Matched on a manifest field name rather than on wording:
            // field names are JSON keys and identical in every
            // implementation, sentences are not. "audio_fields" is a rule
            // rather than a field, and both halves of it name
            // attachment_path.
            let expected = reason == "audio_fields" ? "attachment_path" : reason
            XCTAssertTrue(
                failure.contains(expected),
                "corpus case '\(testCase.name)' was rejected for '\(failure)', "
                    + "which does not mention '\(expected)'")
        }
    }
}

/// Just enough JSON to carry a corpus manifest back out to Foundation,
/// since the cases are deliberately not all decodable as a Manifest.
private struct JSONValue: Decodable {
    let raw: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: JSONValue].self) {
            raw = value.mapValues(\.raw)
        } else if let value = try? container.decode([JSONValue].self) {
            raw = value.map(\.raw)
        } else if let value = try? container.decode(Bool.self) {
            raw = value
        } else if let value = try? container.decode(Int.self) {
            raw = value
        } else if let value = try? container.decode(Double.self) {
            raw = value
        } else if let value = try? container.decode(String.self) {
            raw = value
        } else {
            raw = NSNull()
        }
    }
}
