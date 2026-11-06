import SwiftUI

/// Follows the add mode of desktop's note editor, ts/routes/editor/NoteEditor.svelte.
@MainActor final class AddCardModel: ObservableObject {
    @Published var decks: [Anki_Decks_DeckNameId] = []
    @Published var notetypes: [Anki_Notetypes_NotetypeNameId] = []
    @Published var deck: Int64 = 0
    @Published private(set) var notetype = Anki_Notetypes_Notetype()
    @Published var fields: [String] = []
    @Published var tags = ""
    @Published var error = ""
    @Published var status = ""
    /// A problem the user may choose to add past.
    @Published var warning: String?

    private let session: Session

    init(session: Session) { self.session = session }

    var isCloze: Bool { notetype.config.kind == .cloze }
    /// These notes hold shapes drawn on an image, which a text form can't make.
    var isImageOcclusion: Bool { notetype.config.originalStockKind == .imageOcclusion }
    var hasInput: Bool { fields.contains { !$0.isEmpty } }

    func load() async {
        do {
            let (d, n, defaults, nt) = try await background {
                var r = Anki_Decks_GetDeckNamesRequest()
                r.includeFiltered = false
                let d: Anki_Decks_DeckNames = try Backend.call("get_deck_names", r)
                let n: Anki_Notetypes_NotetypeNames = try Backend.call("get_notetype_names")
                let defaults: Anki_Notes_DeckAndNotetype = try Backend.call("defaults_for_adding", Anki_Notes_DefaultsForAddingRequest())
                var id = Anki_Notetypes_NotetypeId()
                id.ntid = defaults.notetypeID
                let nt: Anki_Notetypes_Notetype = try Backend.call("get_notetype", id)
                return (d.entries, n.entries, defaults, nt)
            }
            decks = d
            notetypes = n
            deck = defaults.deckID
            show(nt)
        } catch { self.error = error.localizedDescription }
    }

    func select(notetype id: Int64) async {
        do {
            let (nt, lastDeck) = try await background {
                var r = Anki_Notetypes_NotetypeId()
                r.ntid = id
                let nt: Anki_Notetypes_Notetype = try Backend.call("get_notetype", r)
                var key = Anki_Config_GetConfigBoolRequest()
                key.key = .addingDefaultsToCurrentDeck
                let toCurrent: Anki_Generic_Bool = try Backend.call("get_config_bool", key)
                let last: Anki_Decks_DeckId? = toCurrent.val ? nil : try Backend.call("default_deck_for_notetype", r)
                return (nt, last?.did ?? 0)
            }
            if lastDeck != 0 { deck = lastDeck }
            show(nt)
        } catch { self.error = error.localizedDescription }
    }

    /// Text already typed stays in its position, like desktop when changing note type.
    private func show(_ nt: Anki_Notetypes_Notetype) {
        fields = nt.fields.indices.map { $0 < fields.count ? fields[$0] : "" }
        notetype = nt
    }

    func add(force: Bool = false) async {
        error = ""
        status = ""
        let (id, deck, texts) = (notetype.id, deck, fields.map(Self.html))
        let tagList = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        do {
            let (state, cards) = try await background {
                var nt = Anki_Notetypes_NotetypeId()
                nt.ntid = id
                var note: Anki_Notes_Note = try Backend.call("new_note", nt)
                note.fields = texts
                note.tags = tagList
                let check: Anki_Notes_NoteFieldsCheckResponse = try Backend.call("note_fields_check", note)
                let allowed = check.state == .normal || (force && (check.state == .duplicate || check.state == .missingCloze))
                guard allowed else { return (check.state, UInt32(0)) }
                var r = Anki_Notes_AddNoteRequest()
                r.note = note
                r.deckID = deck
                let added: Anki_Notes_AddNoteResponse = try Backend.call("add_note", r)
                return (Anki_Notes_NoteFieldsCheckResponse.State.normal, added.changes.count)
            }
            switch state {
            case .normal:
                status = cards == 1 ? "Added 1 card" : "Added \(cards) cards"
                // Tags and sticky fields carry over to the next note.
                fields = zip(fields, notetype.fields).map { $1.config.sticky ? $0 : "" }
                session.changed()
            case .empty: error = "The first field is empty."
            case .duplicate: warning = "A note with this first field already exists."
            case .missingCloze: warning = "You have a cloze note type but have not made any cloze deletions."
            case .notetypeNotCloze: error = "Cloze deletion can only be used on cloze note types."
            case .fieldNotCloze: error = "Cloze deletion can only be used in fields which use the 'cloze:' filter. This is typically the first field."
            default: error = "This note can't be added."
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Fields hold HTML, and this form is plain text, so what's typed must show as typed.
    nonisolated static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
