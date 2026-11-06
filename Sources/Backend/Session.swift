import SwiftUI

/// Owns the collection's open/closed state. iOS may kill a suspended app at any time, so the
/// collection is backed up and closed on entering the background and reopened on return.
@MainActor final class Session: ObservableObject {
    @Published private(set) var isOpen = false
    /// Bumped when the collection changed underneath the UI, such as after a sync or import.
    @Published private(set) var generation = 0
    @Published var error = ""
    /// While set, background transitions leave the collection alone; the operation owns it.
    private var busyCount = 0
    private var inBackground = false
    private var keepAlive = UIBackgroundTaskIdentifier.invalid
    /// Called when iOS is about to suspend the app during held work.
    var onBackgroundExpired: (() -> Void)?
    var isBusy: Bool { busyCount > 0 }

    func open() async {
        guard !isOpen else { return }
        Paths.prepare()
        removeLeftoverDownloads()
        do {
            var r = Anki_Collection_OpenCollectionRequest()
            r.collectionPath = Paths.collection.path
            r.mediaFolderPath = Paths.media.path
            r.mediaDbPath = Paths.mediaDB.path
            try await background { try Backend.run("open_collection", r) }
            isOpen = true
            error = ""
            log("collection opened")
            generation += 1
            // The user may have left while it was opening.
            if inBackground && busyCount == 0 { await close() }
        } catch {
            self.error = "Could not open your collection: \(error.localizedDescription)"
            log("open failed: \(error)")
        }
    }

    /// A full download writes to a temp file before swapping it in. If the app dies first,
    /// the collection is untouched but the file stays behind.
    private func removeLeftoverDownloads() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.root.path)) ?? []
        for n in names where n.hasPrefix(".tmp") {
            try? FileManager.default.removeItem(at: Paths.root.appendingPathComponent(n))
        }
    }

    func backup(force: Bool) async throws {
        var r = Anki_Collection_CreateBackupRequest()
        r.backupFolder = Paths.backups.path
        r.force = force
        r.waitForCompletion = true
        let _: Anki_Generic_Bool = try await background { try Backend.call("create_backup", r) }
    }

    /// Backs up if the configured interval has passed, then closes the collection.
    func close() async {
        guard isOpen else { return }
        isOpen = false
        do { try await backup(force: false) } catch { log("backup failed: \(error)") }
        do { try await background { try Backend.run("close_collection", Anki_Collection_CloseCollectionRequest()) } }
        catch { log("close failed: \(error)") }
        log("collection closed")
    }

    func changed() { generation += 1 }

    /// For operations that must not be interrupted. The screen stays on meanwhile, and iOS
    /// gives a little time to finish if the user leaves the app.
    /// ponytail: that's about 30 seconds. BGContinuedProcessingTask (iOS 26) could allow longer.
    func hold() {
        busyCount += 1
        UIApplication.shared.isIdleTimerDisabled = true
        guard keepAlive == .invalid else { return }
        keepAlive = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.backgroundExpired() }
        }
    }

    func release() async {
        busyCount -= 1
        guard busyCount == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        if inBackground { await close() }
        if busyCount == 0 { endKeepAlive() }
    }

    func backgroundExpired() {
        onBackgroundExpired?()
        endKeepAlive()
    }

    private func endKeepAlive() {
        guard keepAlive != .invalid else { return }
        UIApplication.shared.endBackgroundTask(keepAlive)
        keepAlive = .invalid
    }

    /// For import of a whole collection, which needs the collection closed.
    func markClosed() { isOpen = false }

    func enteredBackground() {
        inBackground = true
        guard busyCount == 0 else { return }
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(id) }
        Task {
            await close()
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    func enteredForeground() async {
        inBackground = false
        await open()
    }
}
