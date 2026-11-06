import SwiftUI
import UniformTypeIdentifiers

struct DataView: View {
    @ObservedObject var sync: SyncModel
    @ObservedObject var data: DataModel
    let web: WebPages
    @State private var showLogin = false
    @State private var picking = false
    @State private var naming = false
    @State private var deckName = ""
    @State private var forcing = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                deckSection
                importSection
            }
            .navigationTitle("Sync & Data")
            .onAppear { Task { await data.refresh() } }
            .onChange(of: sync.busy) { _, b in if !b { Task { await data.refresh() } } }
            .sheet(isPresented: $showLogin) { LoginView(sync: sync) }
            .sheet(isPresented: textShown) { if let f = data.pendingText { TextImportView(data: data, web: web, file: f) } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { r in
                switch r {
                case .success(let url): data.received(url)
                case .failure(let e): data.error = e.localizedDescription
                }
            }
            // Alerts, because confirmation dialogs hide their Cancel button on recent iOS versions.
            .alert(promptTitle, isPresented: promptShown) { promptButtons } message: { Text(promptMessage) }
            .alert("Create Deck", isPresented: $naming) {
                TextField("Deck name", text: $deckName)
                Button("Create") { Task { await data.createDeck(named: deckName) } }
                    .disabled(deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To make a subdeck, use Parent::Child.")
            }
            .alert("Force a full sync?", isPresented: $forcing) {
                Button("Continue", role: .destructive) { Task { await sync.forceFullSync() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("One side will replace the other. Next you'll choose which to keep.")
            }
            .alert("Replace your whole collection?", isPresented: replaceShown) {
                Button("Replace Collection", role: .destructive) {
                    if let f = data.pendingReplace { Task { await data.replaceCollection(f) } }
                }
                Button("Cancel", role: .cancel) { data.pendingReplace = nil }
            } message: {
                Text("Everything on this device (\(data.facts)) is replaced by this file. A backup of the current collection is made first.")
            }
        }
    }

    private var accountSection: some View {
        Section("AnkiWeb") {
            if sync.loggedIn {
                LabeledContent("Account", value: sync.username)
                if !sync.endpoint.isEmpty { LabeledContent("Server", value: sync.endpoint) }
                if !sync.online { Text("Offline. Your work is saved on this device and will sync when you're back online.").font(.footnote) }
                Toggle("Sync media", isOn: $sync.syncMedia)
                Toggle("Sync automatically", isOn: $sync.autoSync)
                Button(sync.busy ? "Syncing…" : "Sync Now") { Task { await sync.sync() } }.disabled(sync.busy)
                if sync.busy { Button("Cancel", role: .cancel) { sync.cancel() } }
                Button("Force Full Sync") { forcing = true }.disabled(sync.busy)
                Button("Sign Out", role: .destructive) { sync.logout() }.disabled(sync.busy)
            } else {
                Button("Sign In") { showLogin = true }
            }
            if !sync.status.isEmpty { Text(sync.status).font(.footnote) }
            if !sync.media.isEmpty { Text(sync.media).font(.footnote).foregroundStyle(.secondary) }
            if !sync.serverMessage.isEmpty { Text(sync.serverMessage).font(.footnote) }
            if !sync.error.isEmpty { Text(sync.error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var deckSection: some View {
        Section("Collection") {
            if !data.facts.isEmpty { Text(data.facts).font(.footnote) }
            Picker("Study deck", selection: Binding(get: { data.currentDeck }, set: { d in Task { await data.select(deck: d) } })) {
                ForEach(data.decks, id: \.id) { Text($0.name).tag($0.id) }
            }
            Button("Create Deck") { deckName = ""; naming = true }.disabled(data.busy || sync.busy)
            if !data.deckError.isEmpty { Text(data.deckError).font(.footnote).foregroundStyle(.red) }
            Button("Check Database") { Task { await data.checkDatabase() } }.disabled(data.busy || sync.busy)
            if !data.checkResult.isEmpty { Text(data.checkResult).font(.footnote) }
            NavigationLink("Backups") { BackupsView(data: data) }
        }
    }

    private var importSection: some View {
        Section("Import") {
            Toggle("Include scheduling", isOn: $data.includeScheduling)
            Button(data.busy ? "Importing…" : "Import File") { picking = true }.disabled(data.busy)
            if !data.status.isEmpty { Text(data.status).font(.footnote) }
            if !data.result.isEmpty { Text(data.result).font(.footnote) }
            if !data.error.isEmpty { Text(data.error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { sync.prompt != nil }, set: { if !$0 { sync.prompt = nil } })
    }
    private var textShown: Binding<Bool> {
        Binding(get: { data.pendingText != nil }, set: { if !$0 { Task { await data.finishText() } } })
    }
    private var replaceShown: Binding<Bool> {
        Binding(get: { data.pendingReplace != nil }, set: { if !$0 { data.pendingReplace = nil } })
    }
    private var promptTitle: String {
        switch sync.prompt {
        case .confirmDownload: "Download from AnkiWeb?"
        case .confirmUpload: "Upload to AnkiWeb?"
        default: "Your collections have diverged"
        }
    }
    private var promptMessage: String {
        switch sync.prompt {
        case .confirmDownload: "This device has no cards, so it will be replaced by your AnkiWeb collection."
        case .confirmUpload: "AnkiWeb has no cards, so it will be replaced by the collection on this device."
        default: "They can't be merged. Choose which side to keep. The other side's changes since your last sync will be lost."
        }
    }
    @ViewBuilder private var promptButtons: some View {
        if sync.prompt != .confirmUpload {
            Button("Download from AnkiWeb", role: .destructive) { Task { await sync.resolve(upload: false) } }
        }
        if sync.prompt != .confirmDownload {
            Button("Upload to AnkiWeb", role: .destructive) { Task { await sync.resolve(upload: true) } }
        }
        Button("Cancel", role: .cancel) { Task { await sync.resolve(upload: nil) } }
    }
}

struct BackupsView: View {
    @ObservedObject var data: DataModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let files = data.backups()
        List {
            Section {
                if files.isEmpty { Text("No backups yet.") }
                ForEach(files, id: \.self) { file in
                    HStack {
                        Text(file.deletingPathExtension().lastPathComponent).font(.footnote)
                        Spacer()
                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Share Backup")
                        Button("Restore") {
                            dismiss()
                            data.received(file)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("Backups contain your cards and scheduling, but not images or audio. Restoring keeps a backup of what's here now.")
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Anki's own text import page, which has the field mapping and duplicate options.
struct TextImportView: View {
    @ObservedObject var data: DataModel
    let web: WebPages
    let file: URL

    var body: some View {
        NavigationStack {
            WebView(w: web.importer)
                .navigationTitle("Import Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { Task { await data.finishText() } }
                    }
                }
        }
        .task { await web.showTextImport(file) }
    }
}

struct LoginView: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var password = ""
    @State private var server = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                }
                Section("Self-hosted server (optional)") {
                    TextField("https://example.com/", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                if !sync.error.isEmpty { Text(sync.error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") {
                        Task {
                            await sync.login(user: user, password: password, server: server)
                            password = ""
                            if sync.loggedIn { dismiss() }
                        }
                    }.disabled(user.isEmpty || password.isEmpty || sync.busy)
                }
            }
        }
    }
}
