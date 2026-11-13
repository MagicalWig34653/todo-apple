import SwiftUI
import TodoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: Screen

/// Channel #brain: talk to the brain (hold the microphone, speak, let go) or write; answers arrive as text and audio.
struct BrainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = BrainModel()

    var body: some View {
        BrainContent(model: model)
            .navigationTitle("view.brain")
            .task {
                await model.load(app)
                model.startPolling(app)
                #if DEBUG
                if DebugVoice.autostart { model.consent.grant(app); await model.beginHold(app) }
                #endif
            }
            .onDisappear { model.stopPolling() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.startPolling(app); Task { await model.refresh(app) } } else { model.stopPolling() }
            }
            .alert(LocalizedStringKey(model.errorKey ?? ""), isPresented: Binding(get: { model.errorKey != nil }, set: { if !$0 { model.errorKey = nil } })) {
                Button("ok") {}
            }
    }
}

/// The screen's content on a given model (also used by the previews with local sample data).
struct BrainContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BrainModel

    private var bottomID: String { "brain.bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.m) {
                    if model.thread.olderCursor != nil {
                        Button("brain.loadOlder") { Task { await model.loadOlder(app) } }
                            .buttonStyle(.bordered).tapTarget()
                            .accessibilityIdentifier("brain.loadOlder")
                    }
                    ForEach(model.messages) { message in
                        BrainBubble(message: message, processing: model.processingIDs.contains(message.id), model: model)
                    }
                    ForEach(model.outgoing) { item in
                        OutgoingBubble(item: item, model: model)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .pageMargins().padding(.vertical, Space.m)
                .readableWidth()
            }
            .background(Color.canvas)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refresh(app) }
            .overlay {
                if !model.thread.loaded {
                    if model.failed { EmptyState(symbol: "wifi.exclamationmark", title: "brain.failed", message: "brain.failedHint") }
                    else { SkeletonRows(count: 3) }
                } else if model.isEmpty {
                    EmptyState(symbol: "waveform", title: "brain.empty", message: "brain.emptyHint", tint: .tilePurple)
                }
            }
            .onChange(of: model.thread.messages.first?.id) { _, _ in withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) } }
            .onChange(of: model.outgoing.count) { _, _ in withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { BrainComposer(model: model) }
        .sheet(isPresented: $model.showConsent) {
            VoiceConsentSheet(
                onAccept: { model.consent.grant(app); model.showConsent = false },
                onDecline: { model.showConsent = false })
        }
        .alert("brain.permission.title", isPresented: $model.showPermissionDenied) {
            Button("brain.permission.open") { PlatformSettings.openMicrophoneSettings() }
            Button("cancel", role: .cancel) {}
        } message: { Text("brain.permission.message") }
    }
}

// MARK: Bubbles

/// Layout metrics of a bubble.
private enum BubbleLook {
    static func tint(_ message: BrainMessage) -> Color { message.isMine ? Color.brand.opacity(0.14) : Color.canvasRaised }
}

private struct BubbleFrame<Content: View>: View {
    let alignment: HorizontalAlignment
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            if alignment == .trailing { Spacer(minLength: BrainMetrics.bubbleMinGap) }
            content
            if alignment == .leading { Spacer(minLength: BrainMetrics.bubbleMinGap) }
        }
    }
}

struct BrainBubble: View {
    @Environment(AppModel.self) private var app
    let message: BrainMessage
    let processing: Bool
    let model: BrainModel

    private var author: LocalizedStringKey { message.isMine ? "brain.author.me" : "brain.author.brain" }

    var body: some View {
        if message.kind == .status {
            statusLine
        } else {
            BubbleFrame(alignment: message.isMine ? .trailing : .leading) {
                VStack(alignment: .leading, spacing: Space.s) {
                    header
                    bodyContent
                }
                .padding(Space.m)
                .background(BubbleLook.tint(message), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(message.isMine ? "brain.message.mine" : "brain.message.brain")
        }
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Text(author).font(.caption.weight(.semibold))
            Text(message.createdAt, format: .dateTime.hour().minute())
            if message.kind == .voiceIn || message.kind == .voiceOut {
                Image(systemName: "waveform").accessibilityHidden(true)
            }
        }
        .font(.caption).foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var bodyContent: some View {
        if message.hasAudio { playRow }
        if !message.trimmedText.isEmpty {
            Text(verbatim: message.trimmedText)
                .font(.body).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("brain.message.text")
        } else if processing {
            HStack(spacing: Space.s) {
                ProgressView()
                Text("brain.processing").font(.subheadline).foregroundStyle(Color.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("brain.processing")
        }
    }

    private var playRow: some View {
        let active = model.player.isActive(message)
        return Button { Task { await model.player.toggle(message, app) } } label: {
            HStack(spacing: Space.s) {
                if model.player.isLoading && model.player.activeID == message.id {
                    ProgressView()
                } else {
                    Image(systemName: active ? "stop.circle.fill" : "play.circle.fill").font(.title2)
                }
                Text(active ? "brain.stop" : (message.isMine ? "brain.playMine" : "brain.play")).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.brand)
            .tapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(active ? "brain.stop" : "brain.play"))
        .accessibilityIdentifier("brain.play")
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text(verbatim: message.trimmedText)
        }
        .font(.footnote).foregroundStyle(Color.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brain.status")
    }
}

/// A message on its way (or failed) at the end of the thread.
struct OutgoingBubble: View {
    @Environment(AppModel.self) private var app
    let item: BrainOutgoing
    let model: BrainModel

    var body: some View {
        BubbleFrame(alignment: .trailing) {
            VStack(alignment: .leading, spacing: Space.s) {
                switch item.kind {
                case .text(let text): Text(verbatim: text).font(.body).fixedSize(horizontal: false, vertical: true)
                case .voice(let seconds):
                    Label { Text("brain.voiceLength \(Int(seconds.rounded()))") } icon: { Image(systemName: "waveform") }.font(.body)
                }
                switch item.state {
                case .sending:
                    HStack(spacing: Space.s) {
                        ProgressView()
                        Text("brain.uploading").font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("brain.uploading")
                case .failed(let key):
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label { Text(LocalizedStringKey(key)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Color.dueOverdue)
                            .accessibilityIdentifier("brain.sendFailed")
                        AdaptiveStack(spacing: Space.s) {
                            Button("brain.retry") { Task { await model.retry(item, app) } }
                                .buttonStyle(.borderedProminent).tapTarget()
                                .accessibilityIdentifier("brain.retry")
                            Button("brain.discard", role: .destructive) { model.discard(item) }
                                .buttonStyle(.bordered).tapTarget()
                        }
                    }
                }
            }
            .padding(Space.m)
            .background(Color.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Composer

/// Text field and microphone: hold the microphone to record, swipe left to discard.
struct BrainComposer: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BrainModel
    @ScaledMetric(relativeTo: .body) private var scaledMic = BrainMetrics.micSide
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Grows with the text but never beyond 1.5x, so the field keeps its room at accessibility sizes.
    private var micSide: CGFloat { min(scaledMic, BrainMetrics.micSide * 1.5) }
    @State private var pressing = false

    private var recording: Bool { model.recorder.isRecording }

    var body: some View {
        VStack(spacing: Space.xs) {
            if let key = model.hintKey, !recording {
                Text(LocalizedStringKey(key)).font(.footnote).foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("brain.hint")
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Space.s)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: Space.s))
            layout {
                if recording {
                    RecordingStrip(recorder: model.recorder, armed: model.cancelArmed)
                } else {
                    TextField(accessible: "brain.composer.placeholder", text: $model.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                        .frame(minHeight: micSide)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Color.hairline, lineWidth: 0.5))
                        .accessibilityIdentifier("brain.composer")
                        .onSubmit { Task { await model.sendText(app) } }
                }
                if !recording && model.canSendText {
                    Button { Task { await model.sendText(app) } } label: {
                        Image(systemName: "arrow.up").font(.headline).foregroundStyle(Color.onBrand)
                            .frame(width: micSide, height: micSide).background(Color.brand, in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text("brain.send"))
                    .accessibilityIdentifier("brain.send")
                } else {
                    micButton
                }
            }
        }
        .pageMargins().padding(.vertical, Space.s)
        .readableWidth()
        .frame(maxWidth: .infinity)
        .background(Color.canvasRaised)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 0.5) }
        .animation(.default, value: recording)
    }

    private var micButton: some View {
        ZStack {
            Circle().fill(recording ? Color.dueOverdue : Color.brand)
            if recording {
                Circle().stroke(Color.onBrand.opacity(0.5), lineWidth: Space.xs)
                    .scaleEffect(1 + CGFloat(model.recorder.level) * 0.35)
                    .opacity(0.8)
            }
            Image(systemName: recording && model.cancelArmed ? "trash" : "mic.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(Color.onBrand)
        }
        .frame(width: micSide, height: micSide)
        .scaleEffect(recording ? 1.15 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressing { pressing = true; Task { await model.beginHold(app) } }
                    model.moveHold(translationX: value.translation.width)
                }
                .onEnded { value in
                    pressing = false
                    Task { await model.endHold(cancelled: value.translation.width < -BrainMetrics.cancelDistance, app) }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(recording ? "brain.a11y.recording" : "brain.a11y.record"))
        .accessibilityValue(Text(recording ? "brain.a11y.seconds \(Int(model.recorder.elapsed))" : ""))
        .accessibilityHint(Text(recording ? "brain.a11y.hintSend" : "brain.a11y.hintRecord"))
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityAction { Task { await model.toggleForAccessibility(app) } }
        .accessibilityAction(named: Text("brain.a11y.discard")) { Task { await model.endHold(cancelled: true, app) } }
        .accessibilityIdentifier("brain.mic")
    }
}

/// While recording: red dot, time, level and the hint for cancelling.
struct RecordingStrip: View {
    let recorder: VoiceRecorder
    let armed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: armed ? "trash.fill" : "record.circle.fill")
                .foregroundStyle(Color.dueOverdue)
                .symbolEffect(.pulse, isActive: !armed && !reduceMotion)
                .accessibilityHidden(true)
            Text(verbatim: clock(recorder.elapsed)).font(.body.monospacedDigit().weight(.semibold))
                .accessibilityIdentifier("brain.recording.time")
            Text(armed ? "brain.release.cancel" : "brain.swipe.cancel")
                .font(.footnote).foregroundStyle(armed ? Color.dueOverdue : Color.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("brain.recording.hint")
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, minHeight: BrainMetrics.micSide, alignment: .leading)
        .background(Color.dueOverdue.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("brain.a11y.recording"))
        .accessibilityValue(Text("brain.a11y.seconds \(Int(recorder.elapsed))"))
        .accessibilityIdentifier("brain.recording")
    }
}

// MARK: Consent

/// First use of voice messages: what is recorded, where it goes, how long it stays, how to revoke (ADR 0030).
struct VoiceConsentSheet: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var onAccept: () -> Void
    var onDecline: () -> Void

    private struct Point: Identifiable {
        let id: String
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let points: [Point] = [
        Point(id: "mic", symbol: "mic.fill", title: "voice.consent.mic.title", text: "voice.consent.mic.text"),
        Point(id: "server", symbol: "externaldrive.fill", title: "voice.consent.server.title", text: "voice.consent.server.text"),
        Point(id: "local", symbol: "desktopcomputer", title: "voice.consent.local.title", text: "voice.consent.local.text"),
        Point(id: "retention", symbol: "clock.arrow.circlepath", title: "voice.consent.retention.title", text: "voice.consent.retention.text"),
        Point(id: "others", symbol: "person.2.fill", title: "voice.consent.others.title", text: "voice.consent.others.text"),
        Point(id: "revoke", symbol: "hand.raised.fill", title: "voice.consent.revoke.title", text: "voice.consent.revoke.text"),
    ]

    private var buttons: some View {
        VStack(spacing: Space.s) {
                    Button(action: onAccept) {
                        Text("voice.consent.accept").font(.headline).foregroundStyle(Color.onBrand)
                            .frame(maxWidth: .infinity).tapTarget()
                            .background(Color.brand, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("voice.consent.accept")
                    Button("voice.consent.decline", action: onDecline).tapTarget()
                        .accessibilityIdentifier("voice.consent.decline")
                }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text("voice.consent.intro").font(.body).fixedSize(horizontal: false, vertical: true)
                    ForEach(points) { point in
                        HStack(alignment: .top, spacing: Space.m) {
                            IconTile(symbol: point.symbol, tint: .tilePurple)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(point.title).font(.headline)
                                Text(point.text).font(.subheadline).foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if typeSize.isAccessibilitySize { buttons }
                }
                .pageMargins().padding(.vertical, Space.l)
                .readableWidth()
            }
            .background(Color.canvas)
            .navigationTitle("voice.consent.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !typeSize.isAccessibilitySize {
                    buttons.pageMargins().padding(.vertical, Space.m).readableWidth().frame(maxWidth: .infinity).background(Color.canvasRaised)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 640)
        #endif
        .presentationDragIndicator(.visible)
    }
}

// MARK: Settings

/// Settings section "Sprachnachrichten": consent state and revoking it.
struct VoiceSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var consent = VoiceConsentModel()
    @State private var showConsent = false
    @State private var confirmRevoke = false

    var body: some View {
        Section {
            if let record = consent.record, consent.isGranted {
                LabeledContent("voice.settings.consent") { Text(record.acceptedAt, format: .dateTime.day().month().year()) }
                    .accessibilityIdentifier("voice.settings.state")
                Button("voice.settings.revoke", role: .destructive) { confirmRevoke = true }
                    .accessibilityIdentifier("voice.settings.revoke")
            } else {
                Text("voice.settings.off").foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("voice.settings.state")
                Button("voice.settings.grant") { showConsent = true }
                    .accessibilityIdentifier("voice.settings.grant")
            }
            Button { app.selection = .brain } label: { Label("voice.settings.open", systemImage: "waveform") }
        } header: { Text("voice.settings.title") } footer: { Text("voice.settings.hint") }
        .task { consent.load(app) }
        .sheet(isPresented: $showConsent) {
            VoiceConsentSheet(onAccept: { consent.grant(app); showConsent = false }, onDecline: { showConsent = false })
        }
        .confirmationDialog("voice.settings.revokeTitle", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("voice.settings.revoke", role: .destructive) { consent.revoke(app) }
        } message: { Text("voice.settings.revokeHint") }
    }
}

enum PlatformSettings {
    @MainActor static func openMicrophoneSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        #endif
    }
}
