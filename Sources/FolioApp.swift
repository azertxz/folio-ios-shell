import SwiftUI
import WebKit

@main
struct FolioApp: App {
    @StateObject private var model = FolioModel()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                HStack {
                    Text("Folio").font(.system(.headline, design: .serif))
                    Spacer()
                    Button("Connection") { model.showConnection = true }.font(.subheadline).disabled(model.breakUntil != nil)
                }.padding(.horizontal).frame(height: 38).background(Color(red: 0.08, green: 0.13, blue: 0.11))
                if model.ready {
                    StudyWebView(model: model).ignoresSafeArea(.container, edges: .bottom)
                }
                else { Spacer(); Text("Connect to your PC to prepare Folio.").padding(); Spacer() }
            }
            .background(Color(red: 0.08, green: 0.13, blue: 0.11).ignoresSafeArea())
            .overlay {
                if let url = model.paperURL {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Exam document").font(.headline)
                            Spacer()
                            Button("Back to my answer") { model.paperURL = nil }
                        }.padding().background(Color(red: 0.08, green: 0.13, blue: 0.11))
                        PaperWebView(url: url).id(url)
                    }.background(Color(red: 0.08, green: 0.13, blue: 0.11)).ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .overlay {
                if let until = model.breakUntil {
                    NativeBreakView(until: until) { model.breakUntil = nil }
                }
            }
            .preferredColorScheme(.dark)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshAfterUpgrade() }
            }
            .sheet(isPresented: $model.showConnection) {
                NavigationStack {
                    Form {
                        Section("Your private PC connection") {
                            Text("Keep Folio running on your PC and enable Tailscale on both devices.")
                            TextField("https://your-pc.your-tailnet.ts.net", text: $model.address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            TextField("Eight-digit pairing code", text: $model.code)
                                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        }
                        Section {
                            Button(model.busy ? "Preparing Folio…" : "Connect and prepare offline content") {
                                Task { await model.connect() }
                            }.disabled(model.busy)
                            if model.busy { ProgressView() }
                            Text(model.status).font(.footnote)
                        }
                        Section("Offline study") {
                            Text("After setup, your decks, timelines and answers stay on this iPhone. Changes sync when your PC and Tailscale are available. Re-signing the same app keeps its data. Export your data before uninstalling.")
                        }
                    }
                    .navigationTitle("Folio connection")
                    .toolbar { if model.ready { Button("Done") { model.showConnection = false } } }
                    .interactiveDismissDisabled(!model.ready || model.busy)
                }
            }
        }
    }
}

struct StudyWebView: UIViewRepresentable {
    @ObservedObject var model: FolioModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.userContentController.add(context.coordinator, name: "folioExport")
        configuration.userContentController.add(context.coordinator, name: "folioNative")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.08, green: 0.13, blue: 0.11, alpha: 1)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let cookie = HTTPCookie(properties: [.domain: "localhost", .path: "/",
            .name: "folio_local_token", .value: LocalServer.localToken,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            view.load(URLRequest(url: LocalServer.address))
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioExport")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioNative")
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private weak var model: FolioModel?
        init(model: FolioModel) { self.model = model }
        // Only our own top-level study page may display app dialogs. Always
        // complete a request, including when the web view is no longer visible.
        private func dialogPresenter(_ webView: WKWebView, frame: WKFrameInfo) -> UIViewController? {
            guard frame.isMainFrame, let url = frame.request.url,
                  url.scheme == "http", url.host == "localhost", url.port == 8765,
                  var presenter = webView.window?.rootViewController else { return nil }
            while let shown = presenter.presentedViewController { presenter = shown }
            guard !(presenter is UIAlertController), !presenter.isBeingDismissed else { return nil }
            return presenter
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let presenter = dialogPresenter(webView, frame: frame) else {
                completionHandler(false); return
            }
            let alert = UIAlertController(title: "Folio", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let presenter = dialogPresenter(webView, frame: frame) else {
                completionHandler(); return
            }
            let alert = UIAlertController(title: "Folio", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let presenter = dialogPresenter(webView, frame: frame) else {
                completionHandler(nil); return
            }
            let alert = UIAlertController(title: "Folio", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                completionHandler(alert?.textFields?.first?.text ?? "")
            })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.host == "localhost" && url.port == 8765 { decisionHandler(.allow) }
            else {
                if ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
            return nil
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "folioNative" {
                guard message.frameInfo.isMainFrame,
                      message.frameInfo.request.url?.host == "localhost",
                      message.frameInfo.request.url?.port == 8765,
                      let body = message.body as? [String: Any] else { return }
                model?.receiveNative(body)
                return
            }
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.host == "localhost",
                  let body = message.body as? [String: String],
                  let name = body["name"], let text = body["data"],
                  text.utf8.count < 16_000_000,
                  ["json", "csv"].contains((name as NSString).pathExtension) else { return }
            do {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FolioExports")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
                try Data(text.utf8).write(to: file, options: .atomic)
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                guard var presenter = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
                while let shown = presenter.presentedViewController { presenter = shown }
                share.popoverPresentationController?.sourceView = presenter.view
                share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                presenter.present(share, animated: true)
            } catch {}
        }
    }
}

// Exam documents have an isolated, nonpersistent browser and no study-data bridge.
struct PaperWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct NativeBreakView: View {
    let until: Date
    let finished: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(ceil(until.timeIntervalSince(context.date))))
            VStack(spacing: 24) {
                Text("SPACE TO RESET").font(.caption).tracking(3).foregroundStyle(Color(red: 0.86, green: 0.92, blue: 0.66))
                Image(systemName: "sparkles").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(Color(red: 0.86, green: 0.92, blue: 0.66))
                Text("Take a five-minute break").font(.system(size: 34, design: .serif)).multilineTextAlignment(.center)
                Text("Stand up, stretch and rest your eyes. Your work is saved and your study time is paused.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).font(.system(size: 78, weight: .regular, design: .serif)).monospacedDigit().accessibilityLabel("Break time remaining")
                Text("Folio will unlock when the break finishes. This break is additional to your study minutes.").font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.08, green: 0.13, blue: 0.11).ignoresSafeArea())
                .onChange(of: seconds, initial: true) { _, value in if value == 0 { finished() } }
        }
    }
}
