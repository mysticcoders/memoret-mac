import CryptoKit
import Foundation
import Sodium

enum CryptoError: LocalizedError {
    case badMagic
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .badMagic: return "sealed blob: bad magic header (not a VVSB v1 blob)"
        case .decryptFailed: return "sealed blob: decryption failed (wrong key or corrupted ciphertext)"
        }
    }
}

struct Keypair {
    let publicKey: [UInt8]
    let privateKey: [UInt8]
}

enum MemoretCrypto {
    static let sealedMagic: [UInt8] = [0x56, 0x56, 0x53, 0x42, 0x01]
    private static let sodium = Sodium()

    /**
     Generates the receiver-owned X25519 keypair. The private key never
     leaves this Mac; only the public key is shared at pairing.
     */
    static func generateKeypair() -> Keypair {
        let kp = sodium.box.keyPair()!
        return Keypair(publicKey: kp.publicKey, privateKey: kp.secretKey)
    }

    /**
     Opens a VVSB v1 sealed blob with the receiver keypair, throwing on a
     bad magic header or failed authentication. Mirrors the contract's
     `open` byte-for-byte.
     */
    static func openSealed(_ blob: [UInt8], keypair: Keypair) throws -> [UInt8] {
        guard blob.count >= sealedMagic.count,
              Array(blob.prefix(sealedMagic.count)) == sealedMagic else {
            throw CryptoError.badMagic
        }
        let sealed = Array(blob.dropFirst(sealedMagic.count))
        guard let plain = sodium.box.open(
            anonymousCipherText: sealed,
            recipientPublicKey: keypair.publicKey,
            recipientSecretKey: keypair.privateKey
        ) else {
            throw CryptoError.decryptFailed
        }
        return plain
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
