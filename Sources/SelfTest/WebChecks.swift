#if SELFTEST
import WebKit

/// Checks that Anki's web code works in the app and that page permissions hold.
@MainActor struct WebChecks {
    let app: AppModel
    private var web: WebPages { app.web }
    private var study: WKWebView { app.web.study }
    private var stats: WKWebView { app.web.stats }

    final class Report {
        var lines: [String] = [], fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { fails += 1 }
            lines.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            log(lines.last!)
        }
    }

    private func until(_ w: WKWebView, _ cond: String, secs: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(secs)
        while Date() < end {
            if await web.js(w, "return !!(\(cond))") as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func snap(_ w: WKWebView, _ name: String) async {
        try? await Task.sleep(for: .milliseconds(400))
        if let i = try? await w.takeSnapshot(configuration: nil), let d = i.pngData() {
            try? d.write(to: Paths.documents.appendingPathComponent(name))
        }
    }

    private func post(_ w: WKWebView, _ path: String, type: String = "application/binary") async -> Int {
        await web.js(w, "const r = await fetch(p, {method:'POST', headers:{'Content-Type':t}, body:new Uint8Array(0)}); return r.status",
                     ["p": path, "t": type]) as? Int ?? -1
    }

    func run() async {
        let r = Report()
        r.check("page loaded with reviewer.js", await web.js(study, "return typeof _showQuestion === 'function'") as? Bool == true)
        r.check("reviewer.css applied", await web.js(study, "return [...document.styleSheets].some(s => (s.href||'').includes('reviewer'))") as? Bool == true)
        r.check("reviewer blocked from getDeckNames", await post(study, "/_anki/getDeckNames") == 403)
        r.check("reviewer blocked from graphs", await post(study, "/_anki/graphs") == 403)
        r.check("reviewer may call i18nResources", await post(study, "/_anki/i18nResources") == 200)
        await web.js(study, "location.href = 'https://example.com/'")
        try? await Task.sleep(for: .milliseconds(600))
        r.check("external navigation blocked", study.url?.scheme == "anki", study.url?.scheme ?? "nil")
        var seen = Set<String>(), n = 0
        while app.study.phase == .question, n < 12 {
            n += 1
            let html = await web.js(study, "return document.querySelector('#qa').innerText + ' ' + document.querySelector('#qa').innerHTML") as? String ?? ""
            if html.contains("日本語") && seen.insert("jp").inserted {
                r.check("unicode card in reviewer.js", true)
                await snap(study, "1-question.png")
                await app.study.reveal()
                r.check("answer revealed", await until(study, "document.querySelector('#answer') && document.querySelector('#qa').innerText.includes('coffee')"))
                await snap(study, "2-answer.png")
                await app.study.answer(.good)
                continue
            }
            if html.contains("sqrt") || html.contains("mjx"), seen.insert("math").inserted {
                r.check("MathJax rendered", await until(study, "document.querySelector('#qa mjx-container, #qa .MathJax, #qa math')"))
                await snap(study, "3-math.png")
            }
            if html.contains("anki-test.png"), seen.insert("img").inserted {
                r.check("media image loaded", await until(study, "document.querySelector('#qa img') && document.querySelector('#qa img').naturalWidth > 0"))
            }
            if html.contains("Capital of France"), seen.insert("js").inserted {
                r.check("card script ran", await until(study, "window.__cardJs === 1"))
            }
            await app.study.reveal()
            await app.study.answer(.easy)
        }
        r.check("all card types seen", seen.count == 4, seen.sorted().joined(separator: ","))
        if await until(study, "document.body.innerText.length > 20", secs: 8) { await snap(study, "4-congrats.png") }
        let congrats = await web.js(study, "return document.body.innerText") as? String ?? ""
        r.check("congrats page", study.url?.path == "/congrats" && congrats.count > 20, String(congrats.prefix(70)).replacingOccurrences(of: "\n", with: " "))
        app.tab = 1
        try? await Task.sleep(for: .milliseconds(1200))
        r.check("graphs page rendered charts", await until(stats, "document.querySelectorAll('svg').length > 3", secs: 15))
        let txt = await web.js(stats, "return document.body.innerText") as? String ?? ""
        r.check("graphs shows the reviews just made", txt.contains("Today") || txt.contains("Reviews"), String(txt.prefix(80)).replacingOccurrences(of: "\n", with: " "))
        await snap(stats, "5-graphs.png")
        r.check("wrong content type blocked", await post(stats, "/_anki/getGraphPreferences", type: "text/plain") == 403)
        r.check("non-exposed method blocked", await post(stats, "/_anki/closeCollection") == 403)
        r.check("trusted page may call API", await post(stats, "/_anki/getGraphPreferences") == 200)
        r.lines.append("\nRESULT: \(r.fails) failed")
        try? r.lines.joined(separator: "\n").write(to: Paths.documents.appendingPathComponent("auto.txt"), atomically: true, encoding: .utf8)
        log("AUTO DONE \(r.fails) failed")
    }
}
#endif
