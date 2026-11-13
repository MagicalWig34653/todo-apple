import SwiftUI
import TodoCore

/// Consent for voice messages, per account and server (ADR 0030). Kept on the device until the server has an endpoint.
@MainActor @Observable
final class VoiceConsentModel {
    private(set) var record: VoiceConsentRecord?
    @ObservationIgnored private let store: any VoiceConsentStore

    init(store: any VoiceConsentStore = UserDefaultsVoiceConsentStore()) { self.store = store }

    var isGranted: Bool { (record?.version ?? 0) >= VoiceConsent.currentVersion }

    func load(_ app: AppModel) {
        guard let id = app.user?.id else { record = nil; return }
        record = store.record(account: id, server: app.serverURL)
    }

    func grant(_ app: AppModel) {
        guard let id = app.user?.id else { return }
        let new = VoiceConsentRecord(version: VoiceConsent.currentVersion, acceptedAt: Date())
        store.save(new, account: id, server: app.serverURL)
        record = new
    }

    /// Voice input off again; downloaded audio is removed from the device. Messages already sent stay in the channel until
    /// the server-side deletion of ADR 0030 step 7 exists.
    func revoke(_ app: AppModel) {
        guard let id = app.user?.id else { return }
        store.revoke(account: id, server: app.serverURL)
        record = nil
        VoicePlayer.clearCache()
    }
}

/// A message the person sent that the server has not accepted yet (recording or text), shown at the end of the thread.
struct BrainOutgoing: Identifiable, Equatable {
    enum Kind: Equatable { case voice(duration: TimeInterval), text(String) }
    enum State: Equatable { case sending, failed(errorKey: String) }

    /// The `clientUUID` of the post: a retry sends the same one, so a lost response never posts twice.
    let id: UUID
    let kind: Kind
    var state: State
    /// Local recording file (voice only), removed once sent or discarded.
    var fileURL: URL?
    /// Set once the recording is uploaded, so a retry skips the upload.
    var attachmentID: UUID?
}

/// State of the #brain screen: the thread, what is on its way, recording and playback.
@MainActor @Observable
final class BrainModel {
    private(set) var thread = BrainThread()
    private(set) var outgoing: [BrainOutgoing] = []
    private(set) var loading = false
    private(set) var loadingOlder = false
    private(set) var failed = false
    var errorKey: String?
    /// Short-lived hint under the composer (too short, limit reached).
    var hintKey: String?

    let recorder = VoiceRecorder()
    let player = VoicePlayer()
    let consent = VoiceConsentModel()
    var showConsent = false
    var showPermissionDenied = false
    var draft = ""
    /// The finger moved far enough to the left: releasing now discards the recording.
    private(set) var cancelArmed = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var holding = false

    static let pollWhileWaiting: Duration = .seconds(3)
    static let pollIdle: Duration = .seconds(15)

    var messages: [BrainMessage] { thread.chronological }
    var processingIDs: Set<UUID> { thread.processingIDs }
    var isEmpty: Bool { thread.loaded && thread.messages.isEmpty && outgoing.isEmpty }
    var isWaiting: Bool { !thread.processingIDs.isEmpty || outgoing.contains { $0.state == .sending } }

    #if DEBUG
    /// Preview data: a loaded thread with local messages and items on their way; nothing talks to a server.
    func seedPreview(_ messages: [BrainMessage], outgoing: [BrainOutgoing] = [], draft: String = "") {
        thread.merge(firstPage: BrainMessagePage(items: messages))
        self.outgoing = outgoing
        self.draft = draft
    }
    #endif

    // MARK: Loading

    func load(_ app: AppModel) async {
        consent.load(app)
        guard let client = app.client, !loading else { return }
        LiveHub.shared.subscribe(self) { [weak self] in await self?.refresh(app) }
        loading = true; defer { loading = false }
        do {
            thread.merge(firstPage: try await client.brainMessages(limit: 50))
            failed = false
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch {
            failed = true
            if !thread.loaded { errorKey = AppModel.key(for: error) }
        }
    }

    /// Silent refetch of the newest page (live hints, polling, pull to refresh). The runner fills the transcript of a
    /// recording that is already in the thread, so the whole first page is merged, not only messages after `since`.
    func refresh(_ app: AppModel) async {
        guard thread.loaded, let client = app.client else { return }
        do {
            thread.merge(firstPage: try await client.brainMessages(limit: 50))
            failed = false
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch { failed = true }
    }

    /// Lighter check while idle: only what is newer than the thread.
    private func refreshNewer(_ app: AppModel) async {
        guard let client = app.client, let newest = thread.newest,
              let page = try? await client.brainMessages(limit: 50, since: newest) else { return }
        thread.merge(newer: page)
    }

    func loadOlder(_ app: AppModel) async {
        guard let client = app.client, let cursor = thread.olderCursor, !loadingOlder else { return }
        loadingOlder = true; defer { loadingOlder = false }
        do { thread.append(olderPage: try await client.brainMessages(limit: 50, cursor: cursor)) }
        catch { failed = true }
    }

    /// The server sends no live hint for the channel yet (ADR 0030 step 6 note), so the open screen polls: quickly while a
    /// recording waits for its answer, slowly otherwise.
    func startPolling(_ app: AppModel) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waiting = self.isWaiting
                try? await Task.sleep(for: waiting ? Self.pollWhileWaiting : Self.pollIdle)
                if Task.isCancelled { return }
                if waiting { await self.refresh(app) } else { await self.refreshNewer(app) }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel(); pollTask = nil
        player.stop()
        if recorder.isRecording { recorder.cancel() }
    }

    // MARK: Text

    var canSendText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= BrainRules.maxTextLength }

    func sendText(_ app: AppModel) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendText else { return }
        draft = ""
        let item = BrainOutgoing(id: UUID(), kind: .text(text), state: .sending)
        outgoing.append(item)
        Haptics.tap()
        await deliver(item.id, app)
    }

    // MARK: Recording

    /// Finger down on the microphone button. Without consent the dialog opens instead; without permission the system asks.
    func beginHold(_ app: AppModel) async {
        guard !holding, !recorder.isRecording else { return }
        holding = true
        hintKey = nil
        guard consent.isGranted else { showConsent = true; return }
        switch VoiceRecorder.permission {
        case .denied: showPermissionDenied = true; return
        case .undetermined:
            if await VoiceRecorder.requestPermission() { hintKey = "brain.hint.permissionGranted" } else { showPermissionDenied = true }
            return
        case .granted: break
        }
        player.stop()
        recorder.onLimit = { [weak self] in
            guard let self else { return }
            self.hintKey = "brain.hint.limit"
            Task { await self.endHold(cancelled: false, app) }
        }
        do {
            try recorder.start()
            Haptics.tap()
        } catch {
            errorKey = "brain.error.recorder"
        }
    }

    func moveHold(translationX: CGFloat) {
        guard recorder.isRecording else { return }
        let armed = translationX < -BrainMetrics.cancelDistance
        if armed != cancelArmed { cancelArmed = armed; Haptics.select() }
    }

    /// Finger up (or the accessibility action): sends the recording, or discards it after a swipe to the left.
    func endHold(cancelled: Bool, _ app: AppModel) async {
        let wasArmed = cancelArmed
        cancelArmed = false
        holding = false
        guard recorder.isRecording else { return }
        if cancelled || wasArmed {
            recorder.cancel()
            Haptics.warning()
            hintKey = "brain.hint.cancelled"
            return
        }
        guard let recording = recorder.finish() else {
            hintKey = "brain.hint.tooShort"
            Haptics.warning()
            return
        }
        let item = BrainOutgoing(id: UUID(), kind: .voice(duration: recording.duration), state: .sending, fileURL: recording.url)
        outgoing.append(item)
        Haptics.success()
        await deliver(item.id, app)
    }

    /// VoiceOver has no "hold": the default action starts, the next one sends.
    func toggleForAccessibility(_ app: AppModel) async {
        if recorder.isRecording { await endHold(cancelled: false, app) } else { await beginHold(app) }
    }

    // MARK: Delivery

    private func update(_ id: UUID, _ change: (inout BrainOutgoing) -> Void) {
        if let i = outgoing.firstIndex(where: { $0.id == id }) { change(&outgoing[i]) }
    }

    /// Uploads (voice) and posts; the same `clientUUID` for every attempt.
    private func deliver(_ id: UUID, _ app: AppModel) async {
        guard let item = outgoing.first(where: { $0.id == id }), let client = app.client else { return }
        update(id) { $0.state = .sending }
        do {
            let result: BrainPostResult
            switch item.kind {
            case .text(let text):
                result = try await client.postBrainText(text, clientUUID: id)
            case .voice:
                var attachmentID = item.attachmentID
                if attachmentID == nil {
                    guard let url = item.fileURL, let data = try? Data(contentsOf: url) else { throw APIError.invalidInput(reason: "voice_unreadable") }
                    attachmentID = try await client.uploadVoiceRecording(data: data).id
                    update(id) { $0.attachmentID = attachmentID }
                }
                result = try await client.postBrainVoice(attachmentID: attachmentID!, clientUUID: id)
            }
            thread.add(result.message)
            finish(id)
        } catch APIError.unauthorized {
            await app.handle(APIError.unauthorized(reason: nil))
        } catch {
            update(id) { $0.state = .failed(errorKey: Self.errorKey(for: error)) }
            Haptics.warning()
        }
        // A fresh page picks up what the server did with it (status line, job).
        await refresh(app)
    }

    func retry(_ item: BrainOutgoing, _ app: AppModel) async { await deliver(item.id, app) }

    func discard(_ item: BrainOutgoing) { finish(item.id) }

    private func finish(_ id: UUID) {
        if let url = outgoing.first(where: { $0.id == id })?.fileURL { try? FileManager.default.removeItem(at: url) }
        outgoing.removeAll { $0.id == id }
    }

    /// Texts for the server's reasons (contracts/voice.yaml); everything else falls back to the generic ones.
    static func errorKey(for error: Error) -> String {
        switch error as? APIError {
        case .server(429, let reason) where reason == "too_many_open_voice_jobs": "brain.error.openJobs"
        case .server(429, let reason) where reason == "too_many_voice_attachments": "brain.error.openJobs"
        case .server(429, _): "brain.error.rate"
        case .server(413, _): "brain.error.tooLarge"
        case .invalidInput(let reason) where reason == "voice_too_long" || reason == "voice_too_large": "brain.error.tooLarge"
        case .transport: "brain.error.offline"
        default: AppModel.key(for: error)
        }
    }
}

/// Sizes of the brain screen, built from the design tokens.
enum BrainMetrics {
    /// How far to the left the finger travels to arm "discard".
    static let cancelDistance: CGFloat = Space.xxl * 3
    /// Visual side of the microphone button (scaled with Dynamic Type; never below `TapTarget.minimum`).
    static let micSide: CGFloat = Space.xxl + Space.xl
    /// Share of the width a bubble may take, so the other side keeps a visible margin.
    static let bubbleMinGap: CGFloat = Space.xxl + Space.l
}
