#if DEBUG
import SwiftUI
import TodoCore

// MARK: Previews of the #brain screen (local sample data, no server)

private enum BrainPreviewData {
    static func message(_ kind: BrainMessageKind, _ author: BrainAuthor, _ text: String?, minutesAgo: Double, audio: Bool = false) -> BrainMessage {
        BrainMessage(id: UUID(), kind: kind, author: author, text: text, attachmentID: audio ? UUID() : nil, clientUUID: nil,
                     createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    static var thread: [BrainMessage] {
        [
            message(.voiceIn, .person, "Was steht heute an?", minutesAgo: 20, audio: true),
            message(.voiceOut, .agent, "Heute stehen zwei Aufgaben an: der Zahnarzttermin um 14 Uhr und die Angebote für die Arbeitsplatte.", minutesAgo: 19, audio: true),
            message(.voiceIn, .person, nil, minutesAgo: 5, audio: true),
            message(.text, .person, "Bitte erinnere mich an die Donaudampfschifffahrtsgesellschaftskapitänsmütze.", minutesAgo: 4),
            message(.status, .agent, "Brain gerade nur per Text erreichbar.", minutesAgo: 4),
        ]
    }

    @MainActor static func model(outgoing: [BrainOutgoing]) -> BrainModel {
        let model = BrainModel()
        model.seedPreview(thread, outgoing: outgoing)
        return model
    }

    static let outgoing = [
        BrainOutgoing(id: UUID(), kind: .voice(duration: 7), state: .sending),
        BrainOutgoing(id: UUID(), kind: .text("Danke dir"), state: .failed(errorKey: "brain.error.offline")),
    ]
}

private struct BrainPreviewHost: View {
    @State private var app = AppModel()
    @State private var model = BrainPreviewData.model(outgoing: BrainPreviewData.outgoing)
    var body: some View {
        NavigationStack { BrainContent(model: model).navigationTitle("view.brain") }.environment(app).environment(TaskMeta())
    }
}

#Preview("Brain light") { BrainPreviewHost().preferredColorScheme(.light) }
#Preview("Brain dark") { BrainPreviewHost().preferredColorScheme(.dark) }
#Preview("Brain accessibility5") { BrainPreviewHost().dynamicTypeSize(.accessibility5) }
#Preview("Brain klein (SE)") { BrainPreviewHost().frame(width: 320, height: 568) }
#Preview("Brain iPad") { BrainPreviewHost().frame(width: 820, height: 1000) }

#Preview("Aufnahme light") { RecordingStrip(recorder: VoiceRecorder(), armed: false).padding().preferredColorScheme(.light) }
#Preview("Aufnahme verwerfen dark") { RecordingStrip(recorder: VoiceRecorder(), armed: true).padding().preferredColorScheme(.dark) }
#Preview("Aufnahme accessibility5") { RecordingStrip(recorder: VoiceRecorder(), armed: false).padding().dynamicTypeSize(.accessibility5) }

#Preview("Einwilligung light") { VoiceConsentSheet(onAccept: {}, onDecline: {}).preferredColorScheme(.light) }
#Preview("Einwilligung dark") { VoiceConsentSheet(onAccept: {}, onDecline: {}).preferredColorScheme(.dark) }
#Preview("Einwilligung accessibility5") { VoiceConsentSheet(onAccept: {}, onDecline: {}).dynamicTypeSize(.accessibility5) }
#endif
