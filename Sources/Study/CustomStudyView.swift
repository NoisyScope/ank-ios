import SwiftUI

struct CustomStudyContext: Identifiable {
    let id: Int64
    let defaults: Anki_Scheduler_CustomStudyDefaultsResponse
}

/// Follows desktop's aqt/customstudy.py and taglimit.py.
struct CustomStudyView: View {
    enum Option: String, CaseIterable, Identifiable {
        case new = "Increase today's new card limit"
        case review = "Increase today's review card limit"
        case forgot = "Review forgotten cards"
        case ahead = "Review ahead"
        case preview = "Preview new cards"
        case cram = "Study by card state or tag"
        var id: String { rawValue }
    }
    enum TagChoice: String, CaseIterable, Identifiable {
        case any = "Any", require = "Require", exclude = "Exclude"
        var id: String { rawValue }
    }
    private static let maxSize = 99999

    @ObservedObject var study: StudyModel
    let context: CustomStudyContext
    @Environment(\.dismiss) private var dismiss
    @State private var option = Option.new
    @State private var value = 0
    @State private var cramKind = Anki_Scheduler_CustomStudyRequest.Cram.CramKind.new
    @State private var tags: [String: TagChoice] = [:]
    @State private var working = false

    private var range: ClosedRange<Int> {
        switch option {
        case .new, .review: -Self.maxSize...Self.maxSize
        case .forgot: 1...30
        default: 1...Self.maxSize
        }
    }

    private var valueLabel: String {
        switch option {
        case .new: "Increase today's new card limit by this many cards"
        case .review: "Increase today's review limit by this many cards"
        case .forgot: "Review cards forgotten in the last number of days"
        case .ahead: "Review ahead by this many days"
        case .preview: "Preview new cards added in the last number of days"
        case .cram: "Number of cards from the deck"
        }
    }

    private func available(_ label: String, _ count: UInt32, _ children: UInt32) -> String {
        "Available \(label) cards: \(count)" + (children > 0 ? " (\(children) in subdecks)" : "")
    }

    private var defaultValue: Int {
        switch option {
        case .new: Int(context.defaults.extendNew)
        case .review: Int(context.defaults.extendReview)
        case .cram: 100
        default: 1
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Option", selection: $option) {
                        ForEach(Option.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    if option == .new { Text(available("new", context.defaults.availableNew, context.defaults.availableNewInChildren)).font(.footnote) }
                    if option == .review { Text(available("review", context.defaults.availableReview, context.defaults.availableReviewInChildren)).font(.footnote) }
                    Text(valueLabel).font(.footnote).foregroundStyle(.secondary)
                    Stepper(value: $value, in: range) {
                        TextField("", value: $value, format: .number.grouping(.never))
                            .keyboardType(.numbersAndPunctuation)
                    }
                    if option == .cram {
                        Picker("Cards", selection: $cramKind) {
                            Text("New cards only").tag(Anki_Scheduler_CustomStudyRequest.Cram.CramKind.new)
                            Text("Due cards only").tag(Anki_Scheduler_CustomStudyRequest.Cram.CramKind.due)
                            Text("All review cards in random order").tag(Anki_Scheduler_CustomStudyRequest.Cram.CramKind.review)
                            Text("All cards in random order (don't reschedule)").tag(Anki_Scheduler_CustomStudyRequest.Cram.CramKind.all)
                        }
                    }
                }
                if option == .cram, !context.defaults.tags.isEmpty {
                    Section("Tags") {
                        ForEach(context.defaults.tags, id: \.name) { tag in
                            Picker(tag.name, selection: Binding(get: { tags[tag.name] ?? .any }, set: { tags[tag.name] = $0 })) {
                                ForEach(TagChoice.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                    }
                }
                if !study.customStudyError.isEmpty {
                    Text(study.customStudyError).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Custom Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { Task { await create() } }.disabled(working || tooManyTags)
                }
            }
            .onAppear {
                value = defaultValue
                for t in context.defaults.tags where t.include || t.exclude { tags[t.name] = t.include ? .require : .exclude }
            }
            .onChange(of: option) { _, _ in
                value = defaultValue
                study.customStudyError = ""
            }
        }
    }

    /// Desktop limits this too, as the search gets slow beyond it.
    private var tooManyTags: Bool { option == .cram && tags.values.filter { $0 != .any }.count > 100 }

    private func create() async {
        working = true
        defer { working = false }
        var r = Anki_Scheduler_CustomStudyRequest()
        r.deckID = context.id
        let n = min(max(value, range.lowerBound), range.upperBound)
        switch option {
        case .new: r.newLimitDelta = Int32(n)
        case .review: r.reviewLimitDelta = Int32(n)
        case .forgot: r.forgotDays = UInt32(n)
        case .ahead: r.reviewAheadDays = UInt32(n)
        case .preview: r.previewDays = UInt32(n)
        case .cram:
            var c = Anki_Scheduler_CustomStudyRequest.Cram()
            c.kind = cramKind
            c.cardLimit = UInt32(n)
            c.tagsToInclude = tags.filter { $0.value == .require }.map(\.key).sorted()
            c.tagsToExclude = tags.filter { $0.value == .exclude }.map(\.key).sorted()
            r.cram = c
        }
        await study.createCustomStudy(r)
    }
}
