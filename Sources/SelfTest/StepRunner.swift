#if SELFTEST
import UIKit

/// Runs a scripted scenario through the app's real models, for tests/ to verify from outside.
@MainActor final class StepRunner {
    let app: AppModel
    var out: [[String: Any]] = []
    init(app: AppModel) { self.app = app }

    func run(_ script: String) async {
        for raw in script.split(separator: ";").map(String.init) {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let t = Date()
            var entry: [String: Any] = ["step": raw]
            do { entry["detail"] = try await step(parts[0], parts.count > 1 ? parts[1] : "") ; entry["ok"] = true }
            catch { entry["ok"] = false; entry["detail"] = "\(error)" }
            entry["ms"] = Int(Date().timeIntervalSince(t) * 1000)
            out.append(entry)
            write()
        }
    }

    /// A refresh ends early when a newer one overtakes it, so the second call is the one to trust.
    private func settle() async {
        await app.study.refresh()
        await app.study.refresh()
    }

    /// An automatic sync may be under way, and a sync asked for meanwhile is skipped.
    private func syncIdle() async throws {
        try await Task.sleep(for: .milliseconds(50))
        while app.sync.isActive { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func webClick(_ command: String) async -> Bool {
        let web = app.web
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            let found = await web.js(web.study, "const a = document.querySelector(`a[href*=\"${c}\"]`); if (!a) return false; a.click(); return true", ["c": command])
            if found as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private func facts() throws -> [String: Any] {
        [
            "notes": try Backend.count("select count() from notes"),
            "cards": try Backend.count("select count() from cards"),
            "revlog": try Backend.count("select count() from revlog"),
            "media": (try? FileManager.default.contentsOfDirectory(atPath: Paths.media.path).count) ?? 0,
            "backups": (try? FileManager.default.contentsOfDirectory(atPath: Paths.backups.path).count) ?? 0,
        ]
    }

    private func write() {
        var doc: [String: Any] = ["steps": out]
        if app.session.isOpen, let f = try? facts() { doc["facts"] = f }
        if let d = try? JSONSerialization.data(withJSONObject: doc, options: .prettyPrinted) {
            try? d.write(to: Paths.documents.appendingPathComponent("steps.json"), options: .atomic)
        }
    }

    private func step(_ name: String, _ value: String) async throws -> String {
        switch name {
        case "open":
            await app.session.open()
            guard app.session.isOpen else { throw BackendError(message: app.session.error) }
            return "open"
        case "close":
            await app.session.close()
            return "closed"
        case "seed":
            try SelfTest.seed()
            return "seeded"
        case "seed-bulk":
            for i in 0..<(Int(value) ?? 300) { try SelfTest.addNote("bulk \(i)", "answer \(i)") }
            return value
        case "login":
            app.sync.restore()
            await app.sync.login(user: SelfTest.arg("--sync-user") ?? "", password: SelfTest.arg("--sync-pass") ?? "", server: SelfTest.arg("--sync-url") ?? "")
            guard app.sync.loggedIn else { throw BackendError(message: app.sync.error) }
            return "logged in"
        case "restore-login":
            app.sync.restore()
            return app.sync.loggedIn ? "token found" : "no token"
        case "sync":
            try await syncIdle()
            app.sync.restore()
            await app.sync.sync()
            let prompt = app.sync.prompt?.rawValue ?? "none"
            if !app.sync.error.isEmpty { throw BackendError(message: app.sync.error) }
            if app.sync.prompt != nil {
                switch value {
                case "upload": await app.sync.resolve(upload: true)
                case "download": await app.sync.resolve(upload: false)
                default: await app.sync.resolve(upload: nil)
                }
                if !app.sync.error.isEmpty { throw BackendError(message: app.sync.error) }
            }
            await app.sync.waitForMedia()
            if !app.sync.error.isEmpty { throw BackendError(message: app.sync.error) }
            return prompt
        case "review":
            try await syncIdle()
            await app.web.load(app.web.study, "/reviewer")
            await settle()
            var n = 0
            while n < (Int(value) ?? 1), app.study.phase == .question {
                await app.study.reveal()
                await app.study.answer(.good)
                n += 1
            }
            if !app.study.error.isEmpty { throw BackendError(message: app.study.error) }
            guard n == (Int(value) ?? 1) else { throw BackendError(message: "only \(n) cards to answer") }
            return "\(n) answered"
        case "deck":
            var n = Anki_Generic_String()
            n.val = value
            let id: Anki_Decks_DeckId = try await background { try Backend.call("get_deck_id_by_name", n) }
            await app.data.select(deck: id.did)
            return "\(id.did)"
        case "create-deck":
            await app.data.createDeck(named: value)
            if !app.data.deckError.isEmpty { throw BackendError(message: app.data.deckError) }
            return app.data.decks.map(\.name).joined(separator: ",")
        case "add-card":
            // type|deck|field^field|tags|force, through the real model. Blank type or deck keeps the default.
            let p = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let m = AddCardModel(session: app.session)
            await m.load()
            let defaults = "\(m.notetype.name)>\(m.decks.first { $0.id == m.deck }?.name ?? "")"
            let offered = m.decks.map(\.name).joined(separator: ",")
            if let id = m.notetypes.first(where: { $0.name == p[0] })?.id { await m.select(notetype: id) }
            if let id = m.decks.first(where: { $0.name == p[1] })?.id { m.deck = id }
            let texts = p[2].split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            m.fields = m.fields.indices.map { $0 < texts.count ? texts[$0] : "" }
            if p.count > 3 { m.tags = p[3] }
            await m.add(force: p.count > 4)
            let left = m.fields.joined(separator: "^")
            return "status=\(m.status)|error=\(m.error)|warning=\(m.warning ?? "")|defaults=\(defaults)|offered=\(offered)|left=\(left)|tags=\(m.tags)"
        case "import-text":
            // Runs Anki's real text import page with its defaults, then reports what it shows.
            guard let c = app.data.stage(Paths.documents.appendingPathComponent(value)) else { throw BackendError(message: app.data.error) }
            let web = app.web
            await web.showTextImport(c)
            let page = web.importer
            let end = Date().addingTimeInterval(20)
            var clicked = false
            while Date() < end {
                if !clicked { clicked = await web.js(page, "const b = document.querySelector('.import')?.closest('button'); b?.click(); return !!b") as? Bool == true }
                else if await web.js(page, "return !document.querySelector('.import') && document.body.innerText.trim().length > 0") as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            let text = await web.js(page, "return document.body.innerText") as? String ?? ""
            try? FileManager.default.removeItem(at: c)
            app.session.changed()
            guard clicked else { throw BackendError(message: "no Import button: \(text.prefix(200))") }
            return text.replacingOccurrences(of: "\n", with: " ")
        case "undo":
            await app.study.undo()
            await settle()
            if !app.study.error.isEmpty { throw BackendError(message: app.study.error) }
            return app.study.undoLabel
        case "undo-label":
            await settle()
            return app.study.undoLabel
        case "revlog":
            return "\(try await background { try Backend.count("select count() from revlog") })"
        case "start":
            // The app's real startup. Reports when the first card showed and whether a sync blocked it.
            let began = Date()
            var finished = false, shown = -1, blocked = false
            let task = Task { await app.start(); finished = true }
            while !finished || shown < 0, Date().timeIntervalSince(began) < 30 {
                if shown < 0, app.study.phase == .question || app.study.phase == .done { shown = Int(Date().timeIntervalSince(began) * 1000) }
                // Syncing after the card is fine. Only a sync before it would make the user wait.
                if shown < 0, app.sync.busy { blocked = true }
                try await Task.sleep(for: .milliseconds(20))
            }
            await task.value
            return "shown=\(shown) blocked=\(blocked)"
        case "online":
            app.sync.setOnline(value == "on")
            try await Task.sleep(for: .milliseconds(100))
            return value
        case "backups":
            return app.data.backups().map(\.lastPathComponent).joined(separator: ",")
        case "restore-latest":
            guard let f = app.data.backups().first else { throw BackendError(message: "no backups") }
            app.data.received(f)
            guard let copy = app.data.pendingReplace else { throw BackendError(message: "no prompt: \(app.data.error)") }
            await app.data.replaceCollection(copy)
            if !app.data.error.isEmpty { throw BackendError(message: app.data.error) }
            return app.data.result
        case "make-backup":
            try await app.session.backup(force: true)
            return "backed up"
        case "orphan":
            // Damage to repair: a card whose note is gone.
            _ = try await background { try Backend.query("delete from notes where id = (select min(id) from notes)") }
            return "removed a note"
        case "check-db":
            await app.data.checkDatabase()
            return app.data.checkResult
        case "force-full":
            try await syncIdle()
            app.sync.restore()
            await app.sync.forceFullSync()
            let prompt = app.sync.prompt?.rawValue ?? "none"
            await app.sync.resolve(upload: nil)
            return prompt
        case "keep-awake":
            try await syncIdle()
            // Whether the screen stays on through a sync, and afterwards doesn't.
            app.sync.restore()
            let task = Task { await app.sync.sync() }
            var seen = false
            while !seen, app.sync.busy || !task.isCancelled {
                if UIApplication.shared.isIdleTimerDisabled { seen = true; break }
                if !app.sync.busy && app.sync.status.isEmpty && app.sync.error.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
                await Task.yield()
            }
            await task.value
            await app.sync.waitForMedia()
            return "during=\(seen) after=\(UIApplication.shared.isIdleTimerDisabled)"
        case "suspend-download":
            try await syncIdle()
            // iOS running out of background time during a full download.
            app.sync.restore()
            await app.sync.sync()
            guard app.sync.prompt != nil else { return "no prompt" }
            let task = Task { await app.sync.resolve(upload: false) }
            await Task.yield()
            app.sync.suspendForTest()
            await task.value
            return app.sync.error
        case "auto":
            app.sync.autoSync = value == "on"
            return value
        case "auto-sync":
            try await syncIdle()
            app.sync.restore()
            await app.sync.syncIfDue()
            return "error=\(app.sync.error)|prompt=\(app.sync.prompt?.rawValue ?? "none")"
        case "manual-sync":
            try await syncIdle()
            app.sync.restore()
            await app.sync.sync()
            return "error=\(app.sync.error)"
        case "tab":
            try await Task.sleep(for: .milliseconds(200))
            return "\(app.tab)"
        case "audit-cards":
            return try await background { try StudyModel.auditCards() }
        case "reveal":
            await settle()
            await app.study.reveal()
            return await app.web.js(app.web.study, "return document.getElementById('qa').innerText") as? String ?? ""
        case "spoken":
            return app.study.speech.history.joined(separator: "+")
        case "voice":
            // lang|voice,voice|name/language/quality,... picks from a made-up list of installed voices.
            let p = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let list = p[2].split(separator: ",").map { v -> Speech.Option in
                let f = v.split(separator: "/").map(String.init)
                return Speech.Option(id: f[0], name: f[0], language: f[1], quality: Int(f[2]) ?? 1)
            }
            return Speech.choose(lang: p[0], voices: p[1].split(separator: ",").map(String.init), from: list) ?? "none"
        case "card-text":
            await settle()
            return await app.web.js(app.web.study, "return document.getElementById('qa').innerText") as? String ?? ""
        case "last-note":
            let n = try await background { try Backend.query("select id, flds, tags from notes order by id desc limit 1") }
            let id = n[0][0], cards = try await background { try Backend.query("select did from cards where nid = \(id)") }
            return "\(n[0][1])|\(n[0][2])|\(cards.count)|\(cards.first?.first ?? 0)"
        case "sticky":
            var name = Anki_Generic_String()
            name.val = value
            try await background {
                let id: Anki_Notetypes_NotetypeId = try Backend.call("get_notetype_id_by_name", name)
                var nt: Anki_Notetypes_Notetype = try Backend.call("get_notetype", id)
                nt.fields[0].config.sticky = true
                try Backend.run("update_notetype", nt)
            }
            return value
        case "easy":
            try await syncIdle()
            await app.web.load(app.web.study, "/reviewer")
            await settle()
            var n = 0
            while n < (Int(value) ?? 1), app.study.phase == .question {
                await app.study.reveal()
                await app.study.answer(.easy)
                n += 1
            }
            guard n == (Int(value) ?? 1) else { throw BackendError(message: "only \(n) cards to answer") }
            return "\(n) answered"
        case "state":
            await settle()
            let d: Anki_Decks_Deck = try await background { try Backend.call("get_current_deck") }
            return "\(d.name)|\(app.study.counts.map(String.init).joined(separator: ","))|\(app.study.phase == .done ? "done" : "cards")"
        case "tap":
            // Clicks a real link on the Congratulations page, as a finger would.
            await settle()
            guard await webClick(value) else { throw BackendError(message: "no \(value) link on page") }
            try await Task.sleep(for: .milliseconds(600))
            return app.study.customStudy != nil ? "sheet open" : app.study.unburyChoice ? "choice shown" : "no sheet"
        case "custom":
            let p = value.split(separator: ":", maxSplits: 2).map(String.init)
            guard let c = app.study.customStudy else { throw BackendError(message: "sheet not open") }
            var r = Anki_Scheduler_CustomStudyRequest()
            r.deckID = c.id
            let n = Int(p[1]) ?? 1
            switch p[0] {
            case "new": r.newLimitDelta = Int32(n)
            case "review": r.reviewLimitDelta = Int32(n)
            case "forgot": r.forgotDays = UInt32(n)
            case "ahead": r.reviewAheadDays = UInt32(n)
            case "preview": r.previewDays = UInt32(n)
            default:
                var cram = Anki_Scheduler_CustomStudyRequest.Cram()
                cram.kind = .all
                cram.cardLimit = UInt32(n)
                if p.count > 2 { cram.tagsToInclude = [p[2]] }
                r.cram = cram
            }
            await app.study.createCustomStudy(r)
            let open = app.study.customStudy != nil
            let err = app.study.customStudyError
            app.study.customStudy = nil
            return open ? "kept open: \(err)" : "created"
        case "tag":
            // Tags every note, so tag filtering has something to match.
            var r = Anki_Tags_NoteIdsAndTagsRequest()
            r.noteIds = (try Backend.query("select id from notes order by id limit 3")).compactMap { $0.first as? Int64 ?? ($0.first as? Int).map(Int64.init) }
            r.tags = value
            let _: Anki_Collection_OpChangesWithCount = try await background { try Backend.call("add_note_tags", r) }
            return value
        case "bury":
            await settle()
            let qc: Anki_Scheduler_QueuedCards = try await background {
                var q = Anki_Scheduler_GetQueuedCardsRequest(); q.fetchLimit = 1
                return try Backend.call("get_queued_cards", q)
            }
            var r = Anki_Scheduler_BuryOrSuspendCardsRequest()
            r.cardIds = qc.cards.map(\.card.id)
            r.mode = .buryUser
            let _: Anki_Collection_OpChangesWithCount = try await background { try Backend.call("bury_or_suspend_cards", r) }
            await settle()
            return "buried \(r.cardIds.count)"
        case "card-bridge":
            // A card's script must not be able to open app screens.
            await app.web.load(app.web.study, "/reviewer")
            await settle()
            await app.web.js(app.web.study, "bridgeCommand('customStudy'); bridgeCommand('unbury')")
            try await Task.sleep(for: .milliseconds(600))
            return app.study.customStudy != nil ? "opened" : "ignored"
        case "add":
            try SelfTest.addNote(value, "added on iOS")
            return value
        case "add-media":
            var r = Anki_Media_AddMediaFileRequest()
            r.desiredName = value
            r.data = Data("ios media \(value)".utf8)
            let got: Anki_Generic_String = try Backend.call("add_media_file", r)
            try SelfTest.addNote("<img src=\"\(got.val)\">", "media note")
            return got.val
        case "import":
            guard let c = app.data.stage(Paths.documents.appendingPathComponent(value)) else { throw BackendError(message: app.data.error) }
            if c.pathExtension == "colpkg" { await app.data.replaceCollection(c) } else { await app.data.importDeck(c) }
            if !app.data.error.isEmpty { throw BackendError(message: app.data.error) }
            return app.data.result
        case "check":
            let r: Anki_Collection_CheckDatabaseResponse = try await background { try Backend.call("check_database") }
            // Problems are reports of what was fixed; tests decide what they mean.
            return r.problems.isEmpty ? "no problems" : r.problems.joined(separator: "; ")
        case "integrity":
            let r = try await background { try Backend.query("pragma integrity_check") }
            let v = r.first?.first as? String ?? "no result"
            if v != "ok" { throw BackendError(message: v) }
            return v
        case "bench":
            var d: [String] = []
            func time(_ label: String, _ f: @escaping @Sendable () throws -> Void) async throws {
                let t = Date()
                try await background(f)
                d.append("\(label)=\(Int(Date().timeIntervalSince(t) * 1000))ms")
            }
            try await time("deck_tree") {
                var r = Anki_Decks_DeckTreeRequest(); r.now = Int64(Date().timeIntervalSince1970)
                let _: Anki_Decks_DeckTreeNode = try Backend.call("deck_tree", r)
            }
            try await time("queue") {
                var r = Anki_Scheduler_GetQueuedCardsRequest(); r.fetchLimit = 1
                let _: Anki_Scheduler_QueuedCards = try Backend.call("get_queued_cards", r)
            }
            try await time("search") {
                var r = Anki_Search_SearchRequest(); r.search = "bulk"
                let _: Anki_Search_SearchResponse = try Backend.call("search_cards", r)
            }
            return d.joined(separator: " ")
        case "burn":
            // Answers cards until killed, recording each answer only after it returns.
            let f = Paths.documents.appendingPathComponent("burn.txt")
            var n = 0
            while true {
                try await background {
                    var q = Anki_Scheduler_GetQueuedCardsRequest(); q.fetchLimit = 1
                    let qc: Anki_Scheduler_QueuedCards = try Backend.call("get_queued_cards", q)
                    guard let c = qc.cards.first else { throw BackendError(message: "queue empty") }
                    var a = Anki_Scheduler_CardAnswer()
                    a.cardID = c.card.id
                    a.currentState = c.states.current
                    a.newState = c.states.again
                    a.rating = .again
                    a.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
                    a.millisecondsTaken = 100
                    try Backend.run("answer_card", a)
                }
                n += 1
                try Data("\(n)".utf8).write(to: f)
            }
        case "idle":
            try await Task.sleep(for: .seconds(Double(value) ?? 30))
            return "idled"
        default:
            throw BackendError(message: "unknown step \(name)")
        }
    }
}
#endif
