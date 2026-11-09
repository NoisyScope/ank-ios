import UIKit
import WebKit

@MainActor func isDark() -> Bool { UIScreen.main.traitCollection.userInterfaceStyle == .dark }

/// Replaces desktop's mediasrv: serves bundled web files and media, and passes page POSTs
/// to the backend under the same access rules.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let web = Bundle.main.bundleURL.appendingPathComponent("web").standardizedFileURL
    private let queue = DispatchQueue(label: "anki.scheme", qos: .userInitiated, attributes: .concurrent)
    private var stopped = Set<ObjectIdentifier>()
    /// SvelteKit routes we ship. Pages outside this list get only the reviewer whitelist.
    private static let routes: Set<String> = ["graphs", "congrats", "deck-options", "card-info", "import-csv"]
    private static let reviewerHTML = """
    <!doctype html><html class="%@" dir="ltr" data-bs-theme="%@"><head><title>Anki</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>:root { --canvas: #f5f5f5; --fg: #020202 } :root[class*=night-mode] { --canvas: #2c2c2c; --fg: #fcfcfc }</style>
    <link rel="stylesheet" href="/_anki/css/reviewer.css"><script src="/_anki/js/reviewer.js"></script></head>
    <body class="card"><div id="_mark" hidden>&#x2605;</div><div id="_flag" hidden>&#x2691;</div><div id="qa" dir="auto"></div></body></html>
    """
    private static let pageFont = """
    <style>html, body, button, input, select, textarea { font-family: -apple-system, system-ui, sans-serif; }
    body { font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; }</style>
    """
    private static let mimeTypes = [
        "js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "html": "text/html", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "json": "application/json",
    ]

    @MainActor func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        let night = isDark()
        let req = task.request
        queue.async { [self] in
            let (status, mime, data) = req.httpMethod == "POST" ? post(req) : get(req, night: night)
            DispatchQueue.main.async { [self] in
                guard stopped.remove(ObjectIdentifier(task)) == nil, let url = req.url else { return }
                let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
                task.didReceive(r); task.didReceive(data); task.didFinish()
            }
        }
    }
    @MainActor func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    private func post(_ req: URLRequest) -> (Int, String, Data) {
        let path = req.url?.path ?? ""
        guard path.hasPrefix("/_anki/"), req.value(forHTTPHeaderField: "Content-Type") == "application/binary" else {
            log("POST \(path) -> 403 (content type)")
            return (403, "text/plain", Data("forbidden".utf8))
        }
        // Handled by desktop's Python, for its window and its card browser.
        if ["importDone", "importDialogRequireClose", "searchInBrowser"].contains(path.dropFirst(7)) { return (200, "application/binary", Data()) }
        var body = req.httpBody ?? Data()
        if req.httpBody == nil, let s = req.httpBodyStream {
            s.open(); defer { s.close() }
            var b = [UInt8](repeating: 0, count: 65536)
            while case let n = s.read(&b, maxLength: b.count), n > 0 { body.append(b, count: n) }
        }
        // Mirrors _have_api_access(): only pages we ship get the wider API.
        let doc = req.mainDocumentURL?.path ?? "/reviewer"
        let restricted = doc == "/reviewer" || !Self.routes.contains(doc.split(separator: "/").first.map(String.init) ?? "")
        let t = Date()
        let (status, data) = Backend.post(String(path.dropFirst("/_anki/".count)), restricted: restricted, body)
        log("POST \(path) in=\(body.count) -> \(status) out=\(data.count) \(Int(Date().timeIntervalSince(t) * 1000))ms")
        return (status, status == 200 ? "application/binary" : "text/plain", data)
    }

    private func get(_ req: URLRequest, night: Bool) -> (Int, String, Data) {
        let path = req.url?.path ?? "/"
        if path == "/reviewer" {
            return (200, "text/html", Data(String(format: Self.reviewerHTML, night ? "night-mode" : "", night ? "dark" : "light").utf8))
        }
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        if Self.routes.contains(first), var html = (try? Data(contentsOf: web.appendingPathComponent("sveltekit/index.html"))).flatMap({ String(data: $0, encoding: .utf8) }) {
            // Same as desktop's _strip_csp_meta for trusted pages.
            html = html.replacingOccurrences(of: #"<meta[^>]*http-equiv=["']?content-security-policy[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            // Desktop's window supplies the font. Without it these pages fall back to Times.
            html = html.replacingOccurrences(of: "</head>", with: Self.pageFont + "</head>")
            return (200, "text/html", Data(html.utf8))
        }
        var url: URL
        if path.hasPrefix("/_app/") { url = web.appendingPathComponent("sveltekit" + path) }
        else if path.hasPrefix("/_anki/") { url = web.appendingPathComponent(String(path.dropFirst(7))) }
        else { url = Paths.media.appendingPathComponent((path as NSString).lastPathComponent) }
        url = url.standardizedFileURL
        let inside = url.path.hasPrefix(web.path + "/") || url.path.hasPrefix(Paths.media.standardizedFileURL.path + "/")
        guard inside, let d = try? Data(contentsOf: url) else {
            log("GET \(path) -> 404")
            return (404, "text/plain", Data("not found".utf8))
        }
        return (200, Self.mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream", d)
    }
}
