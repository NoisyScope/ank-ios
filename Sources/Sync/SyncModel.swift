import Network
import SwiftUI

enum FullSyncPrompt: String, Identifiable {
    case conflict, confirmDownload, confirmUpload
    var id: String { rawValue }
}

/// Follows desktop's aqt/sync.py. A full sync replaces one side entirely, so it always
/// needs the user's confirmation, and a download is preceded by a backup.
@MainActor final class SyncModel: ObservableObject {
    @Published var loggedIn = false
    @Published var busy = false
    @Published var status = ""
    @Published var media = ""
    @Published var error = ""
    @Published var serverMessage = ""
    @Published var prompt: FullSyncPrompt?
    @Published var syncMedia = true
    @AppStorage("syncUsername") var username = ""
    /// A self-hosted server, or the endpoint AnkiWeb redirected us to.
    @AppStorage("syncEndpoint") var endpoint = ""
    /// Like desktop's "Automatically sync on profile open/close".
    @AppStorage("autoSync") var autoSync = true

    private let session: Session
    private var serverMediaUsn: Int32 = 0
    private var mediaTask: Task<Void, Never>?
    private var automatic = false
    private var lastSync: Date?
    /// False when the device has no network. Study never depends on this.
    @Published private(set) var online = true
    /// An automatic sync couldn't get through, so work is waiting to be sent.
    private var retryPending = false
    private var checking = false
    private let path = NWPathMonitor()
    private static let offlineMessage = "No connection. Your work is saved on this device and will sync when you're back online."

    init(session: Session) {
        self.session = session
        session.onBackgroundExpired = { [weak self] in self?.stopForSuspension() }
        path.pathUpdateHandler = { [weak self] p in
            MainActor.assumeIsolated { self?.setOnline(p.status == .satisfied) }
        }
        path.start(queue: .main)
        // Being connected to Wi-Fi doesn't always mean reaching AnkiWeb, and only a change
        // of network reports anything, so a sync that couldn't get through tries again.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.retrySeconds))
                if self?.retryPending == true { await self?.syncIfDue() }
            }
        }
    }

    private static let retrySeconds = 20.0
    var isActive: Bool { busy || checking }

    func setOnline(_ now: Bool) {
        guard now != online else { return }
        online = now
        if now { Task { await syncIfDue() } }
    }

    /// Asks the server without touching the collection, because a sync holds the collection
    /// for as long as the network takes, and studying must never wait for that.
    private func reachable() async -> Bool {
        guard let url = URL(string: endpoint.isEmpty ? "https://sync.ankiweb.net/" : endpoint) else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let probe = URLSession(configuration: config)
        defer { probe.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            _ = try await probe.data(for: request)
            return true
        } catch let e as URLError {
            // Self-hosted servers on plain HTTP are for the sync itself to reach.
            return e.code == .appTransportSecurityRequiresSecureConnection
        } catch { return false }
    }

    private func stopForSuspension() {
        guard busy || mediaTask != nil else { return }
        try? Backend.run("abort_sync")
        try? Backend.run("abort_media_sync")
        error = "Sync stopped because the app was in the background. Open the app and sync again to finish."
        retryPending = true
        log(error)
    }

    private var canAutoSync: Bool {
        autoSync && loggedIn && online && session.isOpen && !busy && !checking && !session.isBusy && prompt == nil
    }

    /// Syncs on its own, at most every `seconds`. A full sync still waits for the user.
    func syncIfDue(olderThan seconds: TimeInterval = 0) async {
        guard canAutoSync else { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < seconds { return }
        automatic = true
        defer { automatic = false }
        await sync()
    }

    /// Sends this session's work when the user leaves the app. Holds the collection open
    /// from here, because it's otherwise closed as soon as the app enters the background.
    func syncOnLeaving() {
        guard canAutoSync, session.isOpen, (try? Backend.count("select mod > ls from col")) == 1 else { return }
        session.hold()
        Task {
            automatic = true
            await sync()
            automatic = false
            await session.release()
        }
    }

    /// Makes the next sync a full one, for when one side needs to replace the other.
    /// Same as desktop's "force changes in one direction" preference.
    func forceFullSync() async {
        do {
            // Both, because a sync doesn't compare schemas unless something has changed.
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            _ = try await background { try Backend.query("update col set scm = \(now), mod = \(now)") }
            await sync()
        } catch { handle(error) }
    }

    func restore() { loggedIn = Keychain.get() != nil }

    private var auth: Anki_Sync_SyncAuth? {
        guard let hkey = Keychain.get() else { return nil }
        var a = Anki_Sync_SyncAuth()
        a.hkey = hkey
        if !endpoint.isEmpty { a.endpoint = endpoint }
        // A stalled connection gives the collection back sooner when nobody asked for this sync.
        if automatic { a.ioTimeoutSecs = 10 }
        return a
    }

    func login(user: String, password: String, server: String) async {
        error = ""
        status = "Signing in…"
        busy = true
        defer { busy = false; status = "" }
        var r = Anki_Sync_SyncLoginRequest()
        r.username = user
        r.password = password
        let url = server.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty { r.endpoint = url }
        do {
            let a: Anki_Sync_SyncAuth = try await background { try Backend.call("sync_login", r) }
            guard Keychain.set(a.hkey) else {
                error = "Signed in, but this device couldn't store your sign-in securely."
                return
            }
            username = user
            endpoint = url
            loggedIn = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logout() {
        Keychain.delete()
        username = ""
        endpoint = ""
        loggedIn = false
    }

    private func handle(_ e: Error, quiet: Bool = false) {
        if let b = e as? BackendError {
            if b.isInterrupted { return }
            if b.isAuth { logout() }
            if b.kind == .networkError {
                retryPending = true
                log("sync: \(e)")
                // Being offline is normal when the app syncs by itself.
                if !automatic && !quiet { error = Self.offlineMessage }
                return
            }
        }
        error = e.localizedDescription
        log("sync error: \(e)")
    }

    private func watchProgress() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if let p: Anki_Collection_Progress = try? await background({ try Backend.call("latest_progress") }) {
                    switch p.value {
                    case .normalSync(let n): status = n.stage
                    case .fullSync(let f) where f.total > 0: status = "Transferring \(Int(f.transferred) * 100 / Int(f.total))%"
                    default: break
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func sync() async {
        guard !busy, !checking else { return }
        guard let auth else {
            loggedIn = false
            error = "Please sign in first."
            return
        }
        await session.open()
        error = ""; serverMessage = ""
        status = "Checking…"
        checking = true
        let connected = online ? await reachable() : false
        checking = false
        guard connected, !busy else {
            status = ""
            if !connected {
                retryPending = true
                if !automatic { error = Self.offlineMessage }
            }
            return
        }
        busy = true
        session.hold()
        let watcher = watchProgress()
        var r = Anki_Sync_SyncCollectionRequest()
        r.auth = auth
        r.syncMedia = syncMedia
        do {
            let out: Anki_Sync_SyncCollectionResponse = try await background { try Backend.call("sync_collection", r) }
            if out.hasNewEndpoint { endpoint = out.newEndpoint }
            serverMessage = out.serverMessage
            serverMediaUsn = out.serverMediaUsn
            switch out.required {
            case .fullSync: prompt = .conflict
            case .fullDownload: prompt = .confirmDownload
            case .fullUpload: prompt = .confirmUpload
            default:
                lastSync = Date()
                retryPending = false
                monitorMedia()
            }
        } catch { handle(error) }
        session.changed()
        watcher.cancel()
        busy = false
        status = ""
        await session.release()
    }

    func resolve(upload: Bool?) async {
        prompt = nil
        guard let upload, let auth else { return }
        await session.open()
        busy = true
        session.hold()
        let watcher = watchProgress()
        var r = Anki_Sync_FullUploadOrDownloadRequest()
        r.auth = auth
        r.upload = upload
        if syncMedia { r.serverUsn = serverMediaUsn }
        do {
            if !upload { try await session.backup(force: true) }
            status = upload ? "Uploading…" : "Downloading…"
            try await background { try Backend.run("full_upload_or_download", r) }
            monitorMedia()
        } catch { handle(error) }
        // The backend reopens the collection whatever the outcome.
        session.changed()
        watcher.cancel()
        busy = false
        status = ""
        await session.release()
    }

    func cancel() { try? Backend.run("abort_sync") }

    private func monitorMedia() {
        guard syncMedia else { return }
        mediaTask?.cancel()
        session.hold()
        mediaTask = Task {
            while !Task.isCancelled {
                do {
                    let s: Anki_Sync_MediaSyncStatusResponse = try await background { try Backend.call("media_sync_status") }
                    guard s.active else { break }
                    media = [s.progress.checked, s.progress.added, s.progress.removed].filter { !$0.isEmpty }.joined(separator: "\n")
                } catch { handle(error, quiet: true); break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !Task.isCancelled { media = ""; mediaTask = nil }
            await session.release()
        }
    }

    func waitForMedia() async { await mediaTask?.value }
    #if SELFTEST
    func suspendForTest() { session.backgroundExpired() }
    #endif
}
