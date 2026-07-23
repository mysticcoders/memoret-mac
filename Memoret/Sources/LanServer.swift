import Foundation
import Network

enum LanServerState {
    case ready
    case failed(String)
}

/**
 Minimal HTTP/1.1 receiver over Network.framework, advertising itself as
 _memoret._tcp via Bonjour. Speaks exactly two routes — GET /ping for
 discovery validation and POST /capture for sealed blob delivery — and
 closes every connection after one response.
 */
final class LanServer {
    static let maxBodyBytes = 64 * 1024 * 1024
    static let maxHeaderBytes = 16 * 1024

    var onCapture: ((Data) -> Void)?
    var onStateChange: ((LanServerState) -> Void)?

    private let port: UInt16
    private let serviceName: String
    private let pingBody: [String: String]
    private let authToken: String
    private let queue = DispatchQueue(label: "memoret.lan")
    private var listener: NWListener?

    init(port: UInt16, serviceName: String, pingBody: [String: String], authToken: String) {
        self.port = port
        self.serviceName = serviceName
        self.pingBody = pingBody
        self.authToken = authToken
    }

    /**
     Binds the listener and publishes the Bonjour service so capture
     devices can discover this receiver without manual IP entry.
     */
    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: serviceName, type: "_memoret._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStateChange?(.ready)
                case .failed(let error):
                    self?.onStateChange?(.failed("Server failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange?(.failed("Could not bind port \(port): \(error.localizedDescription)"))
        }
    }

    /**
     Tears down the socket and the mDNS advertisement.
     */
    func stop() {
        listener?.cancel()
        listener = nil
    }

    /**
     Accepts one connection and reads until a full request (headers plus
     Content-Length body) is buffered, then routes it.
     */
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        var headerEnd: Int? = nil
        var expectedTotal: Int? = nil

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return connection.cancel() }
                if let data { buffer.append(data) }
                if headerEnd == nil {
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        headerEnd = range.upperBound
                        guard let request = HTTPRequest(headerData: buffer[..<range.lowerBound]) else {
                            return self.respond(connection, status: 400, body: ["error": "malformed request"])
                        }
                        if request.contentLength > LanServer.maxBodyBytes {
                            return self.respond(connection, status: 413, body: ["error": "body too large"])
                        }
                        expectedTotal = range.upperBound + request.contentLength
                    } else if buffer.count > LanServer.maxHeaderBytes {
                        return self.respond(connection, status: 431, body: ["error": "headers too large"])
                    }
                }
                if let start = headerEnd, let total = expectedTotal, buffer.count >= total {
                    guard let request = HTTPRequest(headerData: buffer[..<(start - 4)]) else {
                        return self.respond(connection, status: 400, body: ["error": "malformed request"])
                    }
                    let body = buffer[start..<total]
                    return self.route(connection, request: request, body: Data(body))
                }
                if isComplete || error != nil {
                    return connection.cancel()
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    /**
     Dispatches a fully-buffered request to /ping or /capture, enforcing
     bearer auth and the VVSB magic prefix on deliveries.
     */
    private func route(_ connection: NWConnection, request: HTTPRequest, body: Data) {
        if request.method == "GET" && request.path == "/ping" {
            return respond(connection, status: 200, body: pingBody)
        }
        if request.method == "POST" && request.path == "/capture" {
            let presented = (request.headers["authorization"] ?? "").replacingOccurrences(of: "Bearer ", with: "")
            guard MemoretCrypto.timingSafeEqual(presented, authToken) else {
                return respond(connection, status: 401, body: ["error": "unauthorized"])
            }
            let magic = MemoretCrypto.sealedMagic
            guard body.count >= magic.count, [UInt8](body.prefix(magic.count)) == magic else {
                return respond(connection, status: 400, body: ["error": "not a VVSB sealed blob"])
            }
            onCapture?(body)
            return respond(connection, status: 202, body: ["stored": "accepted"])
        }
        respond(connection, status: 404, body: ["error": "not found"])
    }

    /**
     Serializes a JSON response, sends it, and closes the connection.
     */
    private func respond(_ connection: NWConnection, status: Int, body: [String: String]) {
        let reason: [Int: String] = [
            200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
            404: "Not Found", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var response = "HTTP/1.1 \(status) \(reason[status] ?? "OK")\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(payload.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/**
 Parsed request line and headers of a single HTTP/1.1 request; header
 names are lowercased for case-insensitive lookup.
 */
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    var contentLength: Int {
        Int(headers["content-length"] ?? "0") ?? 0
    }

    init?(headerData: Data) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[name] = value
        }
        headers = parsed
    }
}
