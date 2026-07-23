import Foundation
import SwiftUI

struct ReceiverConfig: Codable {
    var publicKey: String
    var privateKey: String
    var authToken: String
    var vaultPath: String
    var ingested: [String]
}

struct RecentCapture: Identifiable {
    let id = UUID()
    let notePath: String
    let receivedAt: Date
}

@MainActor
final class ReceiverModel: ObservableObject {
    static let lanPort: UInt16 = 41832

    @Published var running = false
    @Published var statusDetail = "Starting…"
    @Published var vaultPath = ""
    @Published var recentCaptures: [RecentCapture] = []

    private var config: ReceiverConfig!
    private var keypair: Keypair!
    private var ingested = Set<String>()
    private var server: LanServer?
    private var started = false

    private let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Memoret")

    private var configURL: URL { appSupport.appendingPathComponent("config.json") }
    private var inboxDir: URL { appSupport.appendingPathComponent("inbox") }
    private var failedDir: URL { appSupport.appendingPathComponent("failed") }
    private var vaultRoot: URL { URL(fileURLWithPath: vaultPath) }

    var fingerprint: String {
        keypair == nil ? "" : MemoretCrypto.fingerprint(publicKey: keypair.publicKey)
    }

    /**
     Renders the pairing payload the iOS QR scanner consumes, matching the
     shape emitted by the Obsidian plugin and terminal receivers.
     */
    var pairingJSON: String {
        let hostname = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let payload: [String: Any] = [
            "pubkey": config.publicKey,
            "auth_token": config.authToken,
            "lan_hostname": hostname,
            "lan_port": Int(ReceiverModel.lanPort),
            "label": "Mac (\(hostname))",
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /**
     Loads or creates the receiver identity and vault location, then binds
     the LAN server and drains anything left in the inbox from a previous
     run.
     */
    func start() {
        if started { return }
        started = true
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            try loadOrCreateConfig()
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        } catch {
            statusDetail = "Setup failed: \(error.localizedDescription)"
            return
        }
        startServer()
        drainInbox()
    }

    /**
     Presents a folder picker so the vault can point anywhere — an Obsidian
     vault, iCloud Drive, or a plain folder.
     */
    func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use as Memoret folder"
        panel.directoryURL = vaultRoot
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
            config.vaultPath = url.path
            try? saveConfig()
        }
    }

    /**
     Copies the pairing JSON for manual setup on devices without a camera.
     */
    func copyPairingJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingJSON, forType: .string)
    }

    /**
     Loads the persisted identity or generates a fresh keypair + token on
     first launch, defaulting the vault to ~/Documents/Memoret.
     */
    private func loadOrCreateConfig() throws {
        if let data = try? Data(contentsOf: configURL) {
            config = try JSONDecoder().decode(ReceiverConfig.self, from: data)
        } else {
            let kp = MemoretCrypto.generateKeypair()
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            config = ReceiverConfig(
                publicKey: Data(kp.publicKey).base64EncodedString(),
                privateKey: Data(kp.privateKey).base64EncodedString(),
                authToken: MemoretCrypto.generateAuthToken(),
                vaultPath: documents.appendingPathComponent("Memoret").path,
                ingested: []
            )
            try saveConfig()
        }
        keypair = Keypair(
            publicKey: [UInt8](Data(base64Encoded: config.publicKey)!),
            privateKey: [UInt8](Data(base64Encoded: config.privateKey)!)
        )
        ingested = Set(config.ingested)
        vaultPath = config.vaultPath
    }

    /**
     Persists the config with owner-only permissions since it holds the
     private key.
     */
    private func saveConfig() throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
    }

    /**
     Binds the LAN receiver and advertises it over mDNS. The server hands
     accepted blobs back on the main actor for inbox storage and ingest.
     */
    private func startServer() {
        let fingerprint = MemoretCrypto.fingerprint(publicKey: keypair.publicKey)
        let authToken = config.authToken
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let server = LanServer(
            port: ReceiverModel.lanPort,
            serviceName: "Memoret Mac (\(ProcessInfo.processInfo.hostName))",
            pingBody: ["service": "memoret", "version": version, "fingerprint": fingerprint],
            authToken: authToken
        )
        server.onCapture = { [weak self] blob in
            Task { @MainActor in self?.acceptBlob(blob) }
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.running = true
                    self?.statusDetail = "Listening on port \(ReceiverModel.lanPort)"
                case .failed(let message):
                    self?.running = false
                    self?.statusDetail = message
                }
            }
        }
        server.start()
        self.server = server
    }

    /**
     Stores an accepted sealed blob in the inbox then triggers a drain, so
     a crash between accept and ingest never loses a capture.
     */
    private func acceptBlob(_ blob: Data) {
        let name = "lan-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).sealed"
        do {
            try blob.write(to: inboxDir.appendingPathComponent(name))
        } catch {
            statusDetail = "Inbox write failed: \(error.localizedDescription)"
            return
        }
        drainInbox()
    }

    /**
     Drains the inbox: each sealed blob is decrypted and written into the
     vault, then deleted; blobs that fail are quarantined so one bad file
     cannot wedge the loop.
     */
    private func drainInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "sealed" {
            ingestOne(file)
        }
    }

    /**
     Ingests a single sealed blob file, recording the capture id and
     deleting the blob on success or quarantining it on failure.
     */
    private func ingestOne(_ file: URL) {
        do {
            let blob = try Data(contentsOf: file)
            let result = try Ingest.sealedBlob(blob, keypair: keypair, vaultRoot: vaultRoot, alreadyIngested: ingested)
            if !result.duplicate {
                ingested.insert(result.captureId)
                config.ingested = Array(ingested)
                try? saveConfig()
                recentCaptures.insert(
                    RecentCapture(notePath: result.notePath ?? "", receivedAt: Date()),
                    at: 0
                )
                if recentCaptures.count > 10 { recentCaptures.removeLast() }
            }
            try FileManager.default.removeItem(at: file)
        } catch {
            statusDetail = "Quarantined a bad capture: \(error.localizedDescription)"
            try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(
                at: file,
                to: failedDir.appendingPathComponent(file.lastPathComponent)
            )
        }
    }
}
