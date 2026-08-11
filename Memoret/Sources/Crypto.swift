import CryptoKit
import Foundation

enum CryptoError: LocalizedError {
    case badMagic
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .badMagic: return "sealed blob: bad magic header (not a VVSB v2 blob)"
        case .decryptFailed: return "sealed blob: decryption failed (wrong key or corrupted ciphertext)"
        }
    }
}

struct Keypair {
    let publicKey: [UInt8]
    let privateKey: [UInt8]
}

enum MemoretCrypto {
    /**
     `VVSB`, the stable part of the header. The version byte that follows it
     moves when the crypto does, so the LAN server's pre-check — which only
     needs to tell our bytes from garbage before handing the blob on —
     matches this alone rather than pinning a scheme it does not decrypt at
     that layer.
     */
    static let sealedMagic: [UInt8] = [0x56, 0x56, 0x53, 0x42]

    static let sealedVersion: UInt8 = 0x02

    /**
     The full 11-byte v2 header: magic, version, then the RFC 9180 codepoints
     naming the suite — KEM 0x0020 DHKEM(X25519, HKDF-SHA256), KDF 0x0001
     HKDF-SHA256, AEAD 0x0003 ChaCha20-Poly1305. Also passed as associated
     data, so an edited header fails to open rather than opening as
     something else.
     */
    static let sealedHeader: [UInt8] = [
        0x56, 0x56, 0x53, 0x42, sealedVersion, 0x00, 0x20, 0x00, 0x01, 0x00, 0x03,
    ]

    /** X25519 encapsulated key, fixed width for this suite. */
    private static let encapsulatedKeyBytes = 32

    /**
     Domain separation for the HPKE key schedule. Must stay byte-identical
     across every implementation; a mismatch surfaces only as a failed open,
     a long way from the cause.
     */
    private static let info = Data("memoret/vvsb/2".utf8)

    private static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /**
     Generates the receiver-owned X25519 keypair. The private key never
     leaves this Mac; only the public key is shared at pairing.

     The raw encoding is the one libsodium used, so pairings created under
     v1 keep working — the blob format broke, the keys did not.
     */
    static func generateKeypair() -> Keypair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Keypair(
            publicKey: [UInt8](key.publicKey.rawRepresentation),
            privateKey: [UInt8](key.rawRepresentation)
        )
    }

    /**
     Opens a VVSB v2 sealed blob with the receiver keypair, throwing on a
     header that is not ours or on failed authentication. Mirrors the
     contract's `open` byte-for-byte.
     */
    static func openSealed(_ blob: [UInt8], keypair: Keypair) throws -> [UInt8] {
        let minimum = sealedHeader.count + encapsulatedKeyBytes
        guard blob.count >= minimum,
            Array(blob.prefix(sealedHeader.count)) == sealedHeader
        else {
            throw CryptoError.badMagic
        }

        let enc = Data(blob[sealedHeader.count..<minimum])
        let ciphertext = Data(blob[minimum...])
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(keypair.privateKey))
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: ciphersuite,
                info: info,
                encapsulatedKey: enc
            )
            return [UInt8](try recipient.open(ciphertext, authenticating: Data(sealedHeader)))
        } catch {
            throw CryptoError.decryptFailed
        }
    }

    /**
     Seals plaintext to a recipient public key, prepending the v2 header.

     This receiver never seals in normal operation; it exists so the Swift
     copy of the contract stays faithful to the others and so tests can
     produce their own inputs rather than depending on a checked-in
     ciphertext that nothing would notice going stale.
     */
    static func seal(_ plaintext: [UInt8], recipientPublicKey: [UInt8]) throws -> [UInt8] {
        let recipient = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(recipientPublicKey))
        var sender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: ciphersuite,
            info: info
        )
        let ciphertext = try sender.seal(
            Data(plaintext), authenticating: Data(sealedHeader))
        return sealedHeader + [UInt8](sender.encapsulatedKey) + [UInt8](ciphertext)
    }

    /**
     Computes the receiver identity fingerprint the iOS app matches during
     discovery: the first 16 hex characters of SHA-256 over the raw public
     key bytes.
     */
    static func fingerprint(publicKey: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(publicKey))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /**
     Generates a URL-safe base64 bearer token matching the format the other
     receivers hand out at pairing.
     */
    static func generateAuthToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /**
     Compares a presented bearer token against the expected one in constant
     time so token length and content cannot be probed via timing.
     */
    static func timingSafeEqual(_ a: String, _ b: String) -> Bool {
        let ab = [UInt8](a.utf8)
        let bb = [UInt8](b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
