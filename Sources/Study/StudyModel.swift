import SwiftUI

enum StudyPhase { case loading, question, answer, done }

private struct RenderedCard: Sendable {
    let css, question, answer: String
    let questionAudio, answerAudio: [Anki_CardRendering_TTSTag]
    let autoplay: Bool
    let labels: [String]
}

@MainActor final class StudyModel: ObservableObject {
    @Published var phase = StudyPhase.loading
    @Published var counts: [UInt32] = [0, 0, 0]
    @Published var labels = ["", "", "", ""]
    @Published var error = ""
    let web: WebPages
    private var current: Anki_Scheduler_QueuedCards.QueuedCard?
    private var question = "", answerHTML = ""
    private var shownAt = Date()
    private var latestRefresh = 0
    let speech = Speech()
    /// True while a sync has the collection. Study refreshes again when it ends.
    var paused: () -> Bool = { false }
    @Published private(set) var hasSpeech = false
    /// What Undo would undo, or empty. Anki forgets this on closing the collection or syncing,
    /// so work that has reached AnkiWeb can't be undone here.
    @Published private(set) var undoLabel = ""
    private var questionSpeech: [Anki_CardRendering_TTSTag] = []
    private var answerSpeech: [Anki_CardRendering_TTSTag] = []
    private var autoplay = true
    /// The card last spoken, so refreshes of the same card (after a sync, say) stay quiet.
    private var spokenCard: Int64?

    @Published var customStudy: CustomStudyContext?
    @Published var customStudyError = ""
    @Published var unburyChoice = false

    init(web: WebPages) {
        self.web = web
        web.onCommand = { [weak self] cmd in
            guard let self else { return }
            Task {
                switch cmd {
                case "customStudy": await self.openCustomStudy()
                case "unbury": await self.startUnbury()
                default: break
                }
            }
        }
    }

    /// Joins a partial render. Like desktop, the front is inserted after its audio is taken out,
    /// so the back's own tags don't repeat it.
    private nonisolated static func text(_ nodes: [Anki_CardRendering_RenderedTemplateNode], front: String = "") -> String {
        nodes.map { n in
            switch n.value {
            case .text(let t): t
            case .replacement(let r): r.fieldName == "FrontSide" ? front : r.currentText
            case nil: ""
            }
        }.joined()
    }

    /// Takes the audio out of card text, as desktop's TemplateRenderContext does. Play
    /// markers stay behind where desktop draws its replay buttons; here the Study screen has one.
    private nonisolated static func extractAudio(_ text: String, question: Bool) throws -> (String, [Anki_CardRendering_TTSTag]) {
        var r = Anki_CardRendering_ExtractAvTagsRequest()
        r.text = text
        r.questionSide = question
        let out: Anki_CardRendering_ExtractAvTagsResponse = try Backend.call("extract_av_tags", r)
        let html = out.text.replacingOccurrences(of: #"\[anki:play:[qa]:\d+\]"#, with: "", options: .regularExpression)
        return (html, out.avTags.compactMap { if case .tts(let t) = $0.value { t } else { nil } })
    }

    /// Whether to speak on its own, and whether the back repeats the front's audio.
    private nonisolated static func audioSettings(_ card: Anki_Cards_Card) throws -> (autoplay: Bool, skipQuestion: Bool) {
        var d = Anki_Decks_DeckId()
        d.did = card.originalDeckID != 0 ? card.originalDeckID : card.deckID
        let deck: Anki_Decks_Deck = try Backend.call("get_deck", d)
        var c = Anki_DeckConfig_DeckConfigId()
        c.dcid = deck.normal.configID
        let conf: Anki_DeckConfig_DeckConfig = try Backend.call("get_deck_config", c)
        return (!conf.config.disableAutoplay, conf.config.skipQuestionWhenReplayingAnswer)
    }

    /// Fetches the next card and shows it. Also recovers from a closed or replaced collection.
    func refresh() async {
        guard !paused() else { return }
        latestRefresh += 1
        let id = latestRefresh
        do {
            let next = try await background {
                var req = Anki_Scheduler_GetQueuedCardsRequest()
                req.fetchLimit = 1
                let q: Anki_Scheduler_QueuedCards = try Backend.call("get_queued_cards", req)
                let undo: Anki_Collection_UndoStatus = try Backend.call("get_undo_status")
                guard let c = q.cards.first else { return (q, nil as RenderedCard?, undo.undo) }
                var r = Anki_CardRendering_RenderExistingCardRequest()
                r.cardID = c.card.id
                r.partialRender = true
                let render: Anki_CardRendering_RenderCardResponse = try Backend.call("render_existing_card", r)
                let labels: Anki_Generic_StringList = try Backend.call("describe_next_states", c.states)
                let (qText, qAudio) = try Self.extractAudio(Self.text(render.questionNodes), question: true)
                let (aText, aAudio) = try Self.extractAudio(Self.text(render.answerNodes, front: qText), question: false)
                let audio = try Self.audioSettings(c.card)
                return (q, RenderedCard(css: render.css, question: qText, answer: aText, questionAudio: qAudio,
                                        answerAudio: audio.skipQuestion ? aAudio : qAudio + aAudio,
                                        autoplay: audio.autoplay, labels: labels.vals), undo.undo)
            }
            // Refreshes overlap, and one that finishes late must not show its older card.
            guard id == latestRefresh else { return }
            error = ""
            undoLabel = next.2
            counts = [next.0.newCount, next.0.learningCount, next.0.reviewCount]
            guard let c = next.0.cards.first, let card = next.1 else {
                current = nil
                hasSpeech = false
                speech.stop()
                phase = .done
                await web.load(web.study, "/congrats")
                return
            }
            current = c
            labels = card.labels
            let style = "<style>\(card.css)</style>"
            question = style + card.question
            answerHTML = style + card.answer
            questionSpeech = card.questionAudio
            answerSpeech = card.answerAudio
            autoplay = card.autoplay
            hasSpeech = !card.questionAudio.isEmpty
            await web.ensure(web.study, "/reviewer")
            guard id == latestRefresh else { return }
            let body = "card card\(c.card.templateIdx + 1)" + (isDark() ? " nightMode night_mode" : "")
            await web.js(web.study, "_showQuestion(q, a, b); await new Promise(d => _queueAction(async () => d()))",
                         ["q": question, "a": answerHTML, "b": body])
            guard id == latestRefresh else { return }
            shownAt = Date()
            phase = .question
            if spokenCard != c.card.id {
                spokenCard = c.card.id
                if autoplay { speech.play(questionSpeech) } else { speech.stop() }
            }
        } catch {
            self.error = error.localizedDescription
            log("refresh failed: \(error)")
        }
    }

    func reveal() async {
        await web.js(web.study, "_showAnswer(a); await new Promise(d => _queueAction(async () => d()))", ["a": answerHTML])
        phase = .answer
        hasSpeech = !answerSpeech.isEmpty
        if autoplay { speech.play(answerSpeech) } else { speech.stop() }
    }

    #if SELFTEST
    /// Every card in the collection: how many show markup, and how many have speech.
    nonisolated static func auditCards() throws -> String {
        var markup = 0, spoken = 0
        let ids = try Backend.query("select id from cards").compactMap { $0.first as? Int64 ?? ($0.first as? Int).map(Int64.init) }
        for id in ids {
            var r = Anki_CardRendering_RenderExistingCardRequest()
            r.cardID = id
            r.partialRender = true
            let render: Anki_CardRendering_RenderCardResponse = try Backend.call("render_existing_card", r)
            let (q, qa) = try extractAudio(text(render.questionNodes), question: true)
            let (a, aa) = try extractAudio(text(render.answerNodes, front: q), question: false)
            if q.contains("[anki:") || a.contains("[anki:") { markup += 1 }
            if !(qa + aa).isEmpty { spoken += 1 }
        }
        return "cards=\(ids.count) markup=\(markup) spoken=\(spoken)"
    }
    #endif

    /// Takes back the last change, as desktop's Edit > Undo does, and shows what's next.
    func undo() async {
        do {
            let _: Anki_Collection_OpChangesAfterUndo = try await background { try Backend.call("undo") }
            spokenCard = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
            log("undo failed: \(error)")
        }
    }

    func replaySpeech() { speech.play(phase == .answer ? answerSpeech : questionSpeech) }

    func openCustomStudy() async {
        do {
            let context = try await background {
                let deck: Anki_Decks_Deck = try Backend.call("get_current_deck")
                var r = Anki_Scheduler_CustomStudyDefaultsRequest()
                r.deckID = deck.id
                let defaults: Anki_Scheduler_CustomStudyDefaultsResponse = try Backend.call("custom_study_defaults", r)
                return CustomStudyContext(id: deck.id, defaults: defaults)
            }
            customStudyError = ""
            customStudy = context
        } catch {
            self.error = error.localizedDescription
            log("custom study failed: \(error)")
        }
    }

    /// On failure the sheet stays open, as the cause is most likely an empty search the user can fix.
    func createCustomStudy(_ r: Anki_Scheduler_CustomStudyRequest) async {
        do {
            try await background { try Backend.run("custom_study", r) }
            customStudy = nil
            customStudyError = ""
            await refresh()
        } catch {
            customStudyError = error.localizedDescription
        }
    }

    private func startUnbury() async {
        do {
            let info: Anki_Scheduler_CongratsInfoResponse = try await background { try Backend.call("congrats_info") }
            if info.haveSchedBuried && info.haveUserBuried { unburyChoice = true } else { await unbury(.all) }
        } catch { self.error = error.localizedDescription }
    }

    func unbury(_ mode: Anki_Scheduler_UnburyDeckRequest.Mode) async {
        do {
            try await background {
                let deck: Anki_Decks_Deck = try Backend.call("get_current_deck")
                var r = Anki_Scheduler_UnburyDeckRequest()
                r.deckID = deck.id
                r.mode = mode
                try Backend.run("unbury_deck", r)
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func answer(_ rating: Anki_Scheduler_CardAnswer.Rating) async {
        guard let c = current else { return }
        var a = Anki_Scheduler_CardAnswer()
        a.cardID = c.card.id
        a.currentState = c.states.current
        a.newState = switch rating {
        case .again: c.states.again
        case .hard: c.states.hard
        case .easy: c.states.easy
        default: c.states.good
        }
        a.rating = rating
        a.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        a.millisecondsTaken = UInt32(min(Date().timeIntervalSince(shownAt) * 1000, 60_000))
        do {
            try await background { try Backend.run("answer_card", a) }
            spokenCard = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
            log("answer failed: \(error)")
        }
    }
}
