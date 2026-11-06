import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published var tab = 0
    let session = Session()
    let web = WebPages()
    lazy var study: StudyModel = {
        let s = StudyModel(web: web)
        s.paused = { [unowned self] in sync.busy }
        return s
    }()
    lazy var sync = SyncModel(session: session)
    lazy var data = DataModel(session: session)

    /// The first card comes before any sync, so opening the app never waits for the network.
    func start() async {
        await web.load(web.study, "/reviewer")
        await session.open()
        await study.refresh()
        sync.restore()
        await sync.syncIfDue()
    }
}

struct RootView: View {
    @StateObject var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $app.tab) {
            StudyView(study: app.study, sync: app.sync, session: app.session).tabItem { Label("Study", systemImage: "rectangle.stack") }.tag(0)
            WebView(w: app.web.stats).tabItem { Label("Stats", systemImage: "chart.bar") }.tag(1)
            DataView(sync: app.sync, data: app.data, web: app.web).tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(2)
        }
        .onChange(of: app.tab) { _, t in
            if t == 1 { Task { await app.web.load(app.web.stats, "/graphs") } }
        }
        .onReceive(app.session.$generation.dropFirst()) { _ in Task { await app.study.refresh() } }
        .onChange(of: phase) { _, p in
            switch p {
            case .background:
                app.study.speech.stop()
                app.sync.syncOnLeaving()
                app.session.enteredBackground()
            case .active:
                Task {
                    await app.session.enteredForeground()
                    await app.sync.syncIfDue(olderThan: 300)
                }
            default: break
            }
        }
        // Full syncs always ask, and the question lives on this tab.
        .onReceive(app.sync.$prompt) { p in if p != nil { app.tab = 2 } }
        .onOpenURL { url in app.data.received(url) }
        .task {
            Backend.start()
            #if SELFTEST
            if await SelfTest.runIfRequested(app) { return }
            #endif
            await app.start()
        }
    }
}

@main struct AnkiStudyApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}
