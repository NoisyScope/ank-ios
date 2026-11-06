import SwiftUI

/// Decks, collection facts and importing.
@MainActor final class DataModel: ObservableObject {
    @Published var decks: [Anki_Decks_DeckNameId] = []
    @Published var currentDeck: Int64 = 0
    @Published var facts = ""
    @Published var busy = false
    @Published var status = ""
    @Published var error = ""
    @Published var deckError = ""
    @Published var checkResult = ""
    @Published var result = ""
    @Published var includeScheduling = true
    /// A .colpkg waiting for confirmation, because importing one replaces the collection.
    @Published var pendingReplace: URL?
    /// A text file open in Anki's text import page.
    @Published var pendingText: URL?

    private let session: Session

    init(session: Session) { self.session = session }

    func refresh() async {
        guard session.isOpen else { return }
        do {
            let (d, cur, notes, cards) = try await background {
                var r = Anki_Decks_GetDeckNamesRequest()
                r.includeFiltered = true
                let d: Anki_Decks_DeckNames = try Backend.call("get_deck_names", r)
                let cur: Anki_Decks_Deck = try Backend.call("get_current_deck")
                return (d.entries, cur.id, try Backend.count("select count() from notes"), try Backend.count("select count() from cards"))
            }
            decks = d
            currentDeck = cur
            facts = "\(notes) notes, \(cards) cards, \(d.count) decks"
        } catch { self.error = error.localizedDescription }
    }

    func select(deck: Int64) async {
        var r = Anki_Decks_DeckId()
        r.did = deck
        do {
            try await background { try Backend.run("set_current_deck", r) }
            currentDeck = deck
            session.changed()
        } catch { self.error = error.localizedDescription }
    }

    /// Creates a deck and selects it. As on desktop, a name already in use reuses that deck,
    /// and "Parent::Child" makes a subdeck.
    func createDeck(named raw: String) async {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        deckError = ""
        do {
            let id = try await background { try Self.deckID(named: name) }
            await refresh()
            await select(deck: id)
        } catch { deckError = error.localizedDescription }
    }

    private nonisolated static func deckID(named name: String) throws -> Int64 {
        var n = Anki_Generic_String()
        n.val = name
        do {
            let existing: Anki_Decks_DeckId = try Backend.call("get_deck_id_by_name", n)
            return existing.did
        } catch let e as BackendError where e.kind == .notFoundError {
            var deck: Anki_Decks_Deck = try Backend.call("new_deck")
            deck.name = name
            let added: Anki_Collection_OpChangesWithId = try Backend.call("add_deck", deck)
            return added.id
        }
    }

    /// Finds and repairs problems, as desktop's Check Database does. A sync that reports a
    /// damaged collection asks for this.
    func checkDatabase() async {
        checkResult = "Checking…"
        busy = true
        session.hold()
        do {
            try await session.backup(force: true)
            let r: Anki_Collection_CheckDatabaseResponse = try await background { try Backend.call("check_database") }
            checkResult = r.problems.isEmpty ? "No problems found." : r.problems.joined(separator: "\n")
            session.changed()
        } catch { checkResult = error.localizedDescription }
        busy = false
        await session.release()
        await refresh()
    }

    /// Newest first. Backups hold the collection, without images or audio.
    func backups() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: keys)) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast }
        return files.filter { $0.pathExtension == "colpkg" }.sorted { date($0) > date($1) }
    }

    /// Takes a file from the picker or from "Open in". It's copied first because the
    /// original is only readable for a moment.
    func received(_ url: URL) {
        guard let copy = stage(url) else { return }
        switch copy.pathExtension.lowercased() {
        case "colpkg": pendingReplace = copy
        case "apkg": Task { await importDeck(copy) }
        default: Task { await openText(copy) }
        }
    }

    private func openText(_ file: URL) async {
        error = ""; result = ""
        do {
            try await session.backup(force: true)
            pendingText = file
        } catch { self.error = error.localizedDescription }
    }

    func finishText() async {
        if let f = pendingText { try? FileManager.default.removeItem(at: f) }
        pendingText = nil
        session.changed()
        await refresh()
    }

    func stage(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard ["apkg", "colpkg", "txt", "csv", "tsv"].contains(url.pathExtension.lowercased()) else {
            error = "Only .apkg, .colpkg, .txt, .csv and .tsv files can be imported."
            return nil
        }
        Paths.prepare()
        let copy = Paths.imports.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func watchProgress() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let p: Anki_Collection_Progress = try? await background({ try Backend.call("latest_progress") }),
                   case .importing(let s) = p.value { status = s }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func importDeck(_ file: URL) async {
        error = ""; result = ""
        busy = true
        status = "Importing…"
        session.hold()
        let watcher = watchProgress()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await session.backup(force: true)
            let scheduling = includeScheduling
            let r: Anki_ImportExport_ImportResponse = try await background {
                var q = Anki_ImportExport_ImportAnkiPackageRequest()
                q.packagePath = file.path
                q.options = try Backend.call("get_import_anki_package_presets")
                q.options.withScheduling = scheduling
                return try Backend.call("import_anki_package", q)
            }
            result = "Added \(r.log.new.count), updated \(r.log.updated.count), duplicates \(r.log.duplicate.count)"
            session.changed()
        } catch {
            self.error = error.localizedDescription
            log("import failed: \(error)")
        }
        watcher.cancel()
        busy = false
        status = ""
        await session.release()
        await refresh()
    }

    /// Replaces the whole collection. The current one is backed up first.
    func replaceCollection(_ file: URL) async {
        pendingReplace = nil
        error = ""; result = ""
        var replaced = false
        busy = true
        status = "Restoring…"
        session.hold()
        let watcher = watchProgress()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await session.backup(force: true)
            try await background { try Backend.run("close_collection", Anki_Collection_CloseCollectionRequest()) }
            session.markClosed()
            try await background {
                var q = Anki_ImportExport_ImportCollectionPackageRequest()
                q.colPath = Paths.collection.path
                q.backupPath = file.path
                q.mediaFolder = Paths.media.path
                q.mediaDb = Paths.mediaDB.path
                try Backend.run("import_collection_package", q)
            }
            replaced = true
        } catch {
            self.error = error.localizedDescription
            log("restore failed: \(error)")
        }
        await session.open()
        watcher.cancel()
        busy = false
        status = ""
        await session.release()
        await refresh()
        if replaced { result = "Collection replaced: \(facts). Your next sync will need a full upload or download." }
    }
}
