import Foundation
import Network

/// A loopback-only origin keeps WebKit storage stable and lets Folio run offline.
final class LocalServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.folio.loopback")
    private let root: URL
    private let origin: URL
    private let session: URLSession
    static let address = URL(string: "http://localhost:8765/")!
    static let localToken: String = {
        if let token = UserDefaults.standard.string(forKey: "folioLocalToken") { return token }
        let token = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(token, forKey: "folioLocalToken")
        return token
    }()

    init(root: URL, origin: URL) {
        self.root = root.standardizedFileURL
        self.origin = origin
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.httpCookieStorage = .shared
        self.session = URLSession(configuration: configuration)
    }

    func start(onState: @escaping (Bool, String?) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8765)
        parameters.allowLocalEndpointReuse = true
        let service = try NWListener(using: parameters)
        service.stateUpdateHandler = { state in
            switch state {
            case .ready: DispatchQueue.main.async { onState(true, nil) }
            case .failed(let error): DispatchQueue.main.async { onState(false, error.localizedDescription) }
            default: break
            }
        }
        service.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? DispatchQueue.global())
            self?.receive(connection, buffer: Data())
        }
        listener = service
        service.start(queue: queue)
    }

    func stop() { listener?.cancel(); listener = nil }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var data = buffer
            if let chunk = chunk { data.append(chunk) }
            guard data.count <= 2_200_000 else { self.reply(connection, status: 413, body: Data()); return }
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
                if data.count > 16384 || complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: data) }
                return
            }
            guard let header = String(data: data[..<split.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = header.components(separatedBy: "\r\n")
            let request = (lines.first ?? "").components(separatedBy: " ")
            guard request.count == 3 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            let cookies = (headers["cookie"] ?? "").components(separatedBy: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard cookies.contains("folio_local_token=" + Self.localToken) else {
                self.reply(connection, status: 403, body: Data()); return
            }
            guard headers["transfer-encoding"] == nil else { self.reply(connection, status: 501, body: Data()); return }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 && length <= 2_097_152 else { self.reply(connection, status: 413, body: Data()); return }
            let body = Data(data[split.upperBound...])
            if body.count < length {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: data) }
                return
            }
            let method = request[0]
            let route = request[1].components(separatedBy: "?")[0]
            if route.hasPrefix("/api/") {
                guard ["/api/sync", "/api/status", "/api/data", "/api/identity"].contains(route) else {
                    self.reply(connection, status: 404, body: Data()); return
                }
                var remote = URLRequest(url: self.origin.appendingPathComponent(String(route.dropFirst())))
                remote.httpMethod = method
                if length > 0 { remote.httpBody = body.prefix(length) }
                remote.setValue("application/json", forHTTPHeaderField: "Content-Type")
                self.session.dataTask(with: remote) { responseData, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 503
                    self.reply(connection, status: status,
                               body: responseData ?? Data("{\"error\":\"PC unavailable. Your work remains on this iPhone.\"}".utf8),
                               type: "application/json")
                }.resume()
                return
            }
            guard method == "GET" || method == "HEAD",
                  let decoded = route.removingPercentEncoding,
                  !decoded.contains("\0"), !decoded.contains("\\") else {
                self.reply(connection, status: 400, body: Data()); return
            }
            let relative = decoded == "/" ? "index.html" : String(decoded.dropFirst())
            let file = self.root.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(self.root.path + "/"), let content = try? Data(contentsOf: file) else {
                self.reply(connection, status: 404, body: Data()); return
            }
            let types = ["html": "text/html", "css": "text/css", "mjs": "text/javascript",
                         "js": "text/javascript", "json": "application/json", "svg": "image/svg+xml",
                         "png": "image/png", "webmanifest": "application/manifest+json"]
            self.reply(connection, status: 200, body: content,
                       type: types[file.pathExtension] ?? "application/octet-stream", head: method == "HEAD")
        }
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data,
                       type: String = "text/plain", head: Bool = false) {
        let reason = status == 200 ? "OK" : "Request failed"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var data = Data(headers.utf8)
        if !head { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
