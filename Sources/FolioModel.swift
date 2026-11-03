import Foundation
import CryptoKit
import Combine

struct AssetManifest: Decodable {
    struct Asset: Decodable { let path: String; let sha256: String; let size: Int }
    let schema: Int
    let assets: [Asset]
}

@MainActor
final class FolioModel: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    @Published var status = ""
    @Published var address = UserDefaults.standard.string(forKey: "folioPC") ?? ""
    @Published var code = ""
    @Published var showConnection = false
    private var server: LocalServer?
    private let manager = FileManager.default
    private var base: URL { manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Folio") }
    private var assets: URL { base.appendingPathComponent("public") }

    init() {
        if let origin = validatedOrigin(address), manager.fileExists(atPath: assets.appendingPathComponent("index.html").path) {
            start(origin)
        } else {
            showConnection = true
        }
    }

    func validatedOrigin(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, host.hasSuffix(".ts.net"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.port == nil || parts.port == 443 else { return nil }
        return URL(string: "https://" + host)
    }

    private func start(_ origin: URL) {
        server?.stop()
        let instance = LocalServer(root: assets, origin: origin)
        server = instance
        do {
            try instance.start { [weak self] running, error in
                self?.ready = running
                if let error = error { self?.status = error; self?.showConnection = true }
            }
        } catch { status = error.localizedDescription }
    }

    private func checked(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Folio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed. Check Tailscale, Folio on your PC and the pairing code."])
        }
        return data
    }

    func connect() async {
        guard !busy else { return }
        guard let origin = validatedOrigin(address) else {
            status = "Enter your PC’s private https://…ts.net address."; return
        }
        // A new PC is an explicit data-preservation decision.
        if let previous = UserDefaults.standard.string(forKey: "folioPC"),
           previous != origin.absoluteString, ready {
            status = "Export and sync your current revision data before changing PCs. Reinstall only after saving that export."; return
        }
        busy = true
        defer { busy = false }
        do {
            if !code.isEmpty {
                guard code.count == 8 && code.allSatisfy({ $0.isNumber }) else {
                    status = "Enter the eight-digit pairing code from your PC."; return
                }
                var pair = URLRequest(url: origin.appendingPathComponent("api/pair"))
                pair.httpMethod = "POST"
                pair.setValue("application/json", forHTTPHeaderField: "Content-Type")
                pair.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
                _ = try await checked(pair)
            }
            status = "Downloading your study desk privately from your PC…"
            let data = try await checked(URLRequest(url: origin.appendingPathComponent("api/mobile-manifest")))
            let manifest = try JSONDecoder().decode(AssetManifest.self, from: data)
            let required: Set<String> = ["/index.html", "/src/app.mjs", "/data/cards.json",
                "/data/timelines/russia.json", "/data/timelines/china.json", "/data/timelines/lancastrians.json"]
            guard manifest.schema == 1, manifest.assets.count < 200,
                  required.isSubset(of: Set(manifest.assets.map { $0.path })),
                  manifest.assets.reduce(0, { $0 + max(0, $1.size) }) < 32_000_000 else {
                throw NSError(domain: "Folio", code: 2, userInfo: [NSLocalizedDescriptionKey: "The PC returned an incompatible content manifest."])
            }
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            let staging = base.appendingPathComponent("download-" + UUID().uuidString)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            for (index, asset) in manifest.assets.enumerated() {
                guard asset.path.hasPrefix("/"), !asset.path.contains(".."), !asset.path.contains("%"),
                      !asset.path.contains("?"), !asset.path.contains("\\"), !asset.path.contains("#"),
                      asset.size >= 0, asset.size < 8_000_000 else {
                    throw NSError(domain: "Folio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsafe content path in PC manifest."])
                }
                let relative = String(asset.path.dropFirst())
                let content = try await checked(URLRequest(url: origin.appendingPathComponent(relative)))
                let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
                guard content.count == asset.size, hash == asset.sha256 else {
                    throw NSError(domain: "Folio", code: 4, userInfo: [NSLocalizedDescriptionKey: "Content changed during transfer. Retry the download."])
                }
                let target = staging.appendingPathComponent(relative)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, options: .atomic)
                status = "Preparing offline content · \(index + 1) / \(manifest.assets.count)"
            }
            let backup = base.appendingPathComponent("previous-public")
            ready = false
            server?.stop()
            if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
            if manager.fileExists(atPath: assets.path) { try manager.moveItem(at: assets, to: backup) }
            do { try manager.moveItem(at: staging, to: assets) }
            catch {
                if manager.fileExists(atPath: backup.path) { try? manager.moveItem(at: backup, to: assets) }
                start(origin)
                throw error
            }
            UserDefaults.standard.set(origin.absoluteString, forKey: "folioPC")
            address = origin.absoluteString
            code = ""
            status = "Connected. Your study desk is ready offline."
            showConnection = false
            start(origin)
        } catch { status = error.localizedDescription }
    }
}
