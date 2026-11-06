import SwiftUI
import WebKit

/// Creates the web views and handles what every page shares: navigation limits and JS calls.
@MainActor final class WebPages: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let handler = SchemeHandler()
    /// Loads being waited for. A new load cancels the one before it, and that cancellation
    /// must only end the wait of the load it belongs to, so each is kept with its navigation.
    private var waiting: [ObjectIdentifier: (navigation: WKNavigation?, done: CheckedContinuation<Void, Never>)] = [:]
    private var requested: [ObjectIdentifier: String] = [:]
    lazy var study = make()
    lazy var stats = make()
    lazy var importer = make()
    /// Receives commands from Anki's own pages, such as the Congratulations page's links.
    var onCommand: ((String) -> Void)?
    /// Commands a page may send, with the one page allowed to send each. Cards run third-party
    /// JS and can call bridgeCommand themselves, so anything else is ignored.
    private static let commands = ["customStudy": "/congrats", "unbury": "/congrats"]

    private func make() -> WKWebView {
        let c = WKWebViewConfiguration()
        c.setURLSchemeHandler(handler, forURLScheme: "anki")
        c.userContentController.add(self, name: "anki")
        c.userContentController.addUserScript(WKUserScript(source: """
          window.bridgeCommand = (c, cb) => { webkit.messageHandlers.anki.postMessage('bridge:' + c); };
          window.pycmd = window.bridgeCommand;
          window.addEventListener('error', e => webkit.messageHandlers.anki.postMessage('jserror: ' + e.message + ' @' + e.filename));
          window.addEventListener('unhandledrejection', e => webkit.messageHandlers.anki.postMessage('jsreject: ' + e.reason));
          """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let w = WKWebView(frame: .zero, configuration: c)
        w.navigationDelegate = self
        #if DEBUG
        w.isInspectable = true
        #endif
        return w
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String else { return }
        guard s.hasPrefix("bridge:") else { log("web: \(s.prefix(300))"); return }
        let cmd = String(s.dropFirst(7))
        if m.frameInfo.isMainFrame, let page = Self.commands[cmd], m.webView?.url?.path == page { onCommand?(cmd) }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = a.request.url?.scheme ?? ""
        // javascript: runs in the current page, and Anki's own links use it to send commands.
        if s == "anki" || s == "about" || s == "javascript" { decisionHandler(.allow) } else { log("blocked navigation to \(s):"); decisionHandler(.cancel) }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(w, n) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: any Error) { log("nav fail \(e)"); finish(w, n) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error) { log("nav fail \(e)"); finish(w, n) }
    private func finish(_ w: WKWebView, _ n: WKNavigation?) {
        let key = ObjectIdentifier(w)
        guard let entry = waiting[key], entry.navigation == nil || entry.navigation === n else { return }
        waiting[key] = nil
        entry.done.resume()
    }

    func load(_ w: WKWebView, _ path: String) async {
        waiting.removeValue(forKey: ObjectIdentifier(w))?.done.resume()
        requested[ObjectIdentifier(w)] = path
        await withCheckedContinuation { c in
            let hash = path != "/reviewer" && isDark() ? "#night" : ""
            let navigation = w.load(URLRequest(url: URL(string: "anki://app\(path)\(hash)")!))
            waiting[ObjectIdentifier(w)] = (navigation, c)
        }
    }

    /// Anki's text import page, for a file already copied into the app.
    func showTextImport(_ file: URL) async {
        await load(importer, "/import-csv/" + (file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
    }

    /// Shows a page, or waits for it if it's already on its way. This goes by the page last
    /// asked for, because the web view's own address lags behind a load in either direction.
    func ensure(_ w: WKWebView, _ path: String) async {
        let key = ObjectIdentifier(w)
        guard requested[key] == path else { return await load(w, path) }
        while waiting[key] != nil { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @discardableResult
    func js(_ w: WKWebView, _ s: String, _ a: [String: Any] = [:]) async -> Any? {
        do { return try await w.callAsyncJavaScript(s, arguments: a, contentWorld: .page) }
        catch { log("js error: \(error) in \(s.prefix(60))"); return nil }
    }
}

struct WebView: UIViewRepresentable {
    let w: WKWebView
    func makeUIView(context: Context) -> WKWebView { w }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
