import SwiftUI

struct StudyView: View {
    @ObservedObject var study: StudyModel
    @ObservedObject var sync: SyncModel
    let session: Session
    @State private var adding = false

    var body: some View {
        VStack(spacing: 8) {
            if !study.error.isEmpty { Text(study.error).foregroundStyle(.red).font(.caption) }
            HStack(spacing: 14) {
                Text("\(study.counts[0])").foregroundStyle(.blue)
                Text("\(study.counts[1])").foregroundStyle(.red)
                Text("\(study.counts[2])").foregroundStyle(.green)
            }
            .font(.subheadline.monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    if !study.undoLabel.isEmpty {
                        Button { Task { await study.undo() } } label: {
                            Image(systemName: "arrow.uturn.backward").font(.title3).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Undo \(study.undoLabel)")
                        .disabled(sync.busy)
                    }
                    if study.hasSpeech {
                        Button { study.replaySpeech() } label: {
                            Image(systemName: "speaker.wave.2").font(.title3).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Replay Audio")
                    }
                }
                .padding(.leading, 8)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    if !sync.online && sync.loggedIn {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Offline. Your work is saved and will sync later.")
                    }
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Add Card")
                    .disabled(sync.busy)
                }
                .padding(.trailing, 8)
            }
            WebView(w: study.web.study)
            switch study.phase {
            case .question:
                Button(sync.busy ? "Syncing…" : "Show Answer") { Task { await study.reveal() } }
                    .buttonStyle(.borderedProminent).frame(height: 56).disabled(sync.busy)
            case .answer:
                HStack(spacing: 6) {
                    ForEach(Array(zip(["Again", "Hard", "Good", "Easy"], [Anki_Scheduler_CardAnswer.Rating.again, .hard, .good, .easy]).enumerated()), id: \.offset) { i, item in
                        Button { Task { await study.answer(item.1) } } label: {
                            VStack { Text(study.labels[i]).font(.caption2); Text(item.0).font(.footnote) }.frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 8).frame(height: 56).disabled(sync.busy)
            default: EmptyView()
            }
        }
        .sheet(isPresented: $adding) { AddCardView(session: session) }
        .sheet(item: $study.customStudy) { CustomStudyView(study: study, context: $0) }
        .alert("What would you like to unbury?", isPresented: $study.unburyChoice) {
            Button("Manually Buried Cards") { Task { await study.unbury(.userOnly) } }
            Button("Buried Siblings") { Task { await study.unbury(.schedOnly) } }
            Button("All Buried Cards") { Task { await study.unbury(.all) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
