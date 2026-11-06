#if SELFTEST
import UIKit

/// Test harness driven by launch arguments; compiled out of Release builds.
///   --reset          delete all data first
///   --auto           the web and security checks, writing auto.txt
///   --steps a;b:c    run named steps, writing steps.json after each one
@MainActor enum SelfTest {
    static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    static func runIfRequested(_ app: AppModel) async -> Bool {
        let a = ProcessInfo.processInfo.arguments
        if a.contains("--reset") {
            try? FileManager.default.removeItem(at: Paths.root)
            try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent("app.log"))
            Keychain.delete()
            UserDefaults.standard.removeObject(forKey: "syncEndpoint")
            UserDefaults.standard.removeObject(forKey: "syncUsername")
            UserDefaults.standard.removeObject(forKey: "autoSync")
        }
        if a.contains("--auto") {
            await app.session.open()
            try? seed()
            await app.web.load(app.web.study, "/reviewer")
            await app.study.refresh()
            await WebChecks(app: app).run()
            return true
        }
        if let s = arg("--steps") {
            await StepRunner(app: app).run(s)
            return true
        }
        return false
    }

    static func addNote(_ front: String, _ back: String, deck: Int64 = 1) throws {
        var name = Anki_Generic_String()
        name.val = "Basic"
        let nt: Anki_Notetypes_NotetypeId = try Backend.call("get_notetype_id_by_name", name)
        var note: Anki_Notes_Note = try Backend.call("new_note", nt)
        note.fields[0] = front
        note.fields[1] = back
        var r = Anki_Notes_AddNoteRequest()
        r.note = note
        r.deckID = deck
        let _: Anki_Notes_AddNoteResponse = try Backend.call("add_note", r)
    }

    static func seed() throws {
        guard try Backend.count("select count() from notes") == 0 else { return }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80)).pngData { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        }
        try png.write(to: Paths.media.appendingPathComponent("anki-test.png"))
        for (f, b) in [
            ("日本語 café", "Japanese <b>coffee</b>"),
            (#"\(x = {-b \pm \sqrt{b^2-4ac} \over 2a}\)"#, "The quadratic formula"),
            (#"<img src="anki-test.png">"#, "Image served by the Swift URL handler"),
            ("Capital of France?<script>window.__cardJs = 1</script>", "Paris"),
        ] { try addNote(f, b) }
    }
}
#endif
