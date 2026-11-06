import SwiftUI

struct AddCardView: View {
    @StateObject private var model: AddCardModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Int?
    @State private var discarding = false

    init(session: Session) { _model = StateObject(wrappedValue: AddCardModel(session: session)) }

    var body: some View {
        NavigationStack {
            Form {
                // At the top, because the keyboard covers the bottom of the form.
                if !model.error.isEmpty { Text(model.error).font(.footnote).foregroundStyle(.red) }
                if !model.status.isEmpty { Text(model.status).font(.footnote) }
                if model.notetype.id != 0 { choosers; fieldSections }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if model.hasInput { discarding = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(model.notetype.id == 0 || model.isImageOcclusion)
                }
            }
        }
        .interactiveDismissDisabled(model.hasInput)
        .task { await model.load() }
        .alert("Discard current input?", isPresented: $discarding) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Add this note?", isPresented: warningShown) {
            Button("Add Anyway") { Task { await add(force: true) } }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(model.warning ?? "")
        }
    }

    private func add(force: Bool = false) async {
        await model.add(force: force)
        if !model.status.isEmpty { focus = 0 }
    }

    private var warningShown: Binding<Bool> {
        Binding(get: { model.warning != nil }, set: { if !$0 { model.warning = nil } })
    }

    private var choosers: some View {
        Section {
            Picker("Type", selection: Binding(get: { model.notetype.id }, set: { id in Task { await model.select(notetype: id) } })) {
                ForEach(model.notetypes, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Deck", selection: $model.deck) {
                ForEach(model.decks, id: \.id) { Text($0.name).tag($0.id) }
            }
        } footer: {
            if model.isImageOcclusion {
                Text("Image Occlusion notes can't be added here.")
            } else if model.isCloze {
                Text("Hide text like this: {{c1::text}}. Use c2, c3 and so on for more cards.")
            }
        }
    }

    @ViewBuilder private var fieldSections: some View {
        ForEach(Array(model.notetype.fields.enumerated()), id: \.offset) { i, field in
            Section(field.name) {
                TextField("", text: fieldText(i), axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focus, equals: i)
            }
        }
        Section("Tags") {
            TextField("Separated by spaces", text: $model.tags)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    /// Bounds-checked, because the field count changes with the note type.
    private func fieldText(_ i: Int) -> Binding<String> {
        Binding(get: { i < model.fields.count ? model.fields[i] : "" },
                set: { if i < model.fields.count { model.fields[i] = $0 } })
    }
}
