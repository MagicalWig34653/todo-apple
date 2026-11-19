import SwiftUI
import TodoCore

// Review with variants (card 1D9C8B0C, contract command-center 1.8.0). Look and behaviour follow the PWA: one card per variant
// (picture only when the variant has an attachment, tag, label, description, "Wählen"), one tap accepts the review with exactly
// that variant (no extra dialog; the safety net is the undo bar), afterwards the chosen variant stands there with the others as
// small labels. Logic (what needs a choice, wording, keyboard steps) lives in TodoCore (`ReviewVariants.swift`).

/// "Wahl nötig": state as symbol and text, never only colour.
struct ChoiceNeededBadge: View {
    var body: some View {
        Label("review.variants.badge", systemImage: "hand.tap.fill")
            .font(.caption2.weight(.semibold)).foregroundStyle(Color.chipPurple)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background(Color.chipPurple.opacity(0.10), in: Capsule())
    }
}

/// The picture area of a variant: the authenticated attachment preview, 16:9, cropped. Only called for a variant with an attachment.
private struct VariantPicture: View {
    let attachmentID: UUID
    let accessibilityText: Text
    let onFailure: () -> Void
    private static let aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        RemoteImage(attachmentID: attachmentID, onFailure: onFailure)
            .aspectRatio(Self.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(Color.hairline, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }
}

/// Small fallback when an attachment has no loadable preview (for example a PDF): label and a note, no empty picture area.
private struct VariantPreviewFallback: View {
    let label: String
    var body: some View {
        Label {
            Text("review.variants.noPreview \(label)").lineLimit(2).multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "photo.badge.exclamationmark")
        }
        .font(.caption).foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hairline.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }
}

/// One variant as a card with its own "Wählen" button.
private struct VariantCard: View {
    let variant: ReviewVariant
    let busy: Bool
    let choosing: Bool
    let focus: FocusState<String?>.Binding
    let onChoose: () -> Void
    @State private var pictureFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            switch variant.previewState(loadFailed: pictureFailed) {
            case .image:
                if let id = variant.attachmentID {
                    VariantPicture(attachmentID: id, accessibilityText: Text("review.variants.imageA11y \(variant.name) \(variant.label)")) { pictureFailed = true }
                }
            case .fallback: VariantPreviewFallback(label: variant.label)
            case .none: EmptyView()
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("review.variants.tag \(variant.name)").font(.caption.weight(.semibold)).foregroundStyle(Color.chipPurple)
                Text(verbatim: variant.label).font(.headline).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let description = variant.description {
                    Text(verbatim: description).font(.footnote).foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Button(action: onChoose) {
                HStack(spacing: Space.s) {
                    if choosing { ProgressView().controlSize(.small) }
                    Text(choosing ? "review.variants.saving" : "review.variants.choose")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.brand).foregroundStyle(Color.onBrand)
            .controlSize(.large).tapTarget()
            .disabled(busy)
            .focused(focus, equals: variant.id)
            .accessibilityLabel(Text("review.variants.choose.a11y \(variant.name) \(variant.label)"))
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// The offered variants of a pending review: heading, hint with the undo window, adaptive grid of cards.
/// Hardware keyboard (Mac, iPad): arrow keys and Home/End move focus between the "Wählen" buttons (stopping at the ends), Return
/// chooses the focused one; Tab and Space stay native.
struct ReviewVariantsView: View {
    let variants: [ReviewVariant]
    /// A decision is running: all buttons wait.
    let busy: Bool
    /// Id of the variant being saved.
    let choosingID: String?
    let onChoose: (String) -> Void
    @FocusState private var focused: String?
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("review.variants.title").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("review.variants.hint \(ReviewUndo.windowMinutes)").font(.caption).foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: Space.m, alignment: .top)], alignment: .leading, spacing: Space.m) {
                ForEach(variants) { v in
                    VariantCard(variant: v, busy: busy, choosing: choosingID == v.id, focus: $focused) { onChoose(v.id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
            guard press.modifiers.isEmpty, let current = focused, let from = variants.firstIndex(where: { $0.id == current }) else { return .ignored }
            let step: VariantNavigation
            switch press.key {
            case .rightArrow, .downArrow: step = .next
            case .leftArrow, .upArrow: step = .previous
            case .home: step = .first
            default: step = .last
            }
            if let index = step.index(from: from, count: variants.count) { focused = variants[index].id }
            return .handled
        }
        .onKeyPress(.return) {
            guard !busy, let id = focused, variants.contains(where: { $0.id == id }) else { return .ignored }
            onChoose(id)
            return .handled
        }
    }
}

/// The accepted review's choice: the chosen variant (with its picture when it has one) and the others as small labels.
struct ChosenVariantView: View {
    let review: any ReviewVariantSource
    let chosen: ReviewVariant
    @State private var pictureFailed = false
    @ScaledMetric(relativeTo: .body) private var pictureWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if chosen.previewState(loadFailed: pictureFailed) == .fallback { VariantPreviewFallback(label: chosen.label) }
            AdaptiveStack(spacing: Space.m, verticalAlignment: .top) {
                if chosen.previewState(loadFailed: pictureFailed) == .image, let id = chosen.attachmentID {
                    VariantPicture(attachmentID: id, accessibilityText: Text("review.variants.imageA11y \(chosen.name) \(chosen.label)")) { pictureFailed = true }
                        .frame(maxWidth: pictureWidth)
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("review.variants.tag \(chosen.name)").font(.caption.weight(.semibold)).foregroundStyle(Color.chipPurple)
                    Text(verbatim: chosen.label).font(.headline).multilineTextAlignment(.leading)
                    if let description = chosen.description {
                        Text(verbatim: description).font(.footnote).foregroundStyle(Color.textSecondary).multilineTextAlignment(.leading)
                    }
                }
            }
            let others = review.otherVariants
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("review.variants.others").font(.caption).foregroundStyle(Color.textSecondary)
                    FlowLayout(spacing: Space.xs) {
                        ForEach(others) { v in
                            Text("review.variants.other \(v.name) \(v.label)").font(.caption).foregroundStyle(Color.textSecondary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                                .background(Color.hairline.opacity(0.4), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.variants.chosen")
    }
}

// MARK: Undo bar

/// An open undo offer for the last review decision: shown as a bar at the bottom while the server's window (`ReviewUndo.window`)
/// lasts, with what was decided ("Variante B gewählt: Radarkarte"), "Rückgängig" and the remaining time.
struct ReviewUndoOffer: Equatable, Sendable {
    let taskID: UUID
    let until: Date
    let message: String
}

struct ReviewUndoBar: View {
    @Environment(AppModel.self) private var app
    let offer: ReviewUndoOffer
    @State private var undoing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = ReviewUndo.remaining(until: offer.until, now: context.date)
            VStack(alignment: .leading, spacing: Space.s) {
                Label {
                    Text(verbatim: offer.message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tileGreen)
                }
                AdaptiveStack(spacing: Space.m) {
                    Button {
                        guard !undoing else { return }
                        undoing = true
                        Task { await app.undoReviewDecision(offer); undoing = false }
                    } label: {
                        Label("review.undo.button", systemImage: "arrow.uturn.backward").tapTarget()
                    }
                    .buttonStyle(.bordered).controlSize(.large).disabled(undoing)
                    .accessibilityHint(Text("review.undo.hint \(Int((left / 60).rounded(.up)))"))
                    Text("review.undo.left \(ReviewUndo.format(left))").font(.caption).monospacedDigit().foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radius.m)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review.undo.bar")
        }
        .task(id: offer) {
            AccessibilityNotification.Announcement(offer.message).post()
            let wait = ReviewUndo.remaining(until: offer.until)
            try? await Task.sleep(for: .seconds(wait))
            app.expireReviewUndo(offer)
        }
    }
}

extension View {
    /// Shows the open review undo offer as a bar at the bottom edge (content moves up instead of being covered).
    func reviewUndoBar(_ enabled: Bool = true) -> some View { modifier(ReviewUndoHost(enabled: enabled)) }
}

private struct ReviewUndoHost: ViewModifier {
    @Environment(AppModel.self) private var app
    let enabled: Bool
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if enabled, let offer = app.reviewUndo {
                ReviewUndoBar(offer: offer).pageMargins().padding(.vertical, Space.s).readableWidth()
            }
        }
    }
}

// MARK: Previews

#if DEBUG
enum VariantPreviewData {
    static let withPictures: [ReviewVariant] = [
        ReviewVariant(id: "a", label: "Windkarte", description: "Wind als Pfeile über der Strecke, ruhig und lesbar.", attachmentID: UUID()),
        ReviewVariant(id: "b", label: "Radarkarte", description: "Niederschlagsradar mit Zeitleiste.", attachmentID: UUID()),
        ReviewVariant(id: "c", label: "Temperaturkarte"),
    ]
    static let textOnly: [ReviewVariant] = [
        ReviewVariant(id: "a", label: "Open-Meteo", description: "Kostenlos, ohne Schlüssel, Rate-Limit großzügig."),
        ReviewVariant(id: "b", label: "Wetterdienst A", description: "Genauere Regenvorhersage, kostenpflichtig ab 1.000 Abrufen am Tag."),
    ]
    static let longWords: [ReviewVariant] = [
        ReviewVariant(id: "a", label: "Niederschlagswahrscheinlichkeitsdarstellung", description: "Donaudampfschifffahrtsgesellschaftskapitänsmütze als Beispiel für sehr lange Wörter."),
        ReviewVariant(id: "b", label: "Kurz"),
    ]
}

extension VariantPreviewData {
    /// A review as the server sends it, with the given variants (self-contained sample data, no network).
    static func review(state: String = "pending", variants: [ReviewVariant], chosen: String? = nil) -> Review {
        let list = variants.map { v in
            var parts = [#""id":"\#(v.id)""#, #""label":"\#(v.label)""#]
            if let d = v.description { parts.append(#""description":"\#(d)""#) }
            if let a = v.attachmentID { parts.append(#""attachmentID":"\#(a.uuidString)""#) }
            return "{" + parts.joined(separator: ",") + "}"
        }.joined(separator: ",")
        let chosenField = chosen.map { #","chosenVariantID":"\#($0)""# } ?? ""
        let json = #"{"id":"\#(UUID())","taskID":"\#(UUID())","state":"\#(state)","requestedByType":"Integration","requestedByLabel":"Claude","summary":"Kartenwahl für die Wetter-Startseite: drei Entwürfe, bitte eine wählen.","version":1,"variants":[\#(list)]\#(chosenField)}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Review.self, from: Data(json.utf8))
    }
}

private struct ReviewWithVariantsPreview: View {
    let variants: [ReviewVariant]
    var body: some View {
        ScrollView {
            ReviewDecisionView(summary: "Kartenwahl für die Wetter-Startseite: drei Entwürfe, bitte eine wählen.", requestedBy: "Claude", requestedAt: nil,
                               taskTitle: "Kartenwahl ShowerNow", variants: variants, busy: false, onDecision: { _, _ in }, onChoose: { _ in })
                .pageMargins().padding(.vertical, Space.l)
        }
        .background(Color.canvas)
        .environment(AppModel())
    }
}

private struct ChosenPreview: View {
    let variants: [ReviewVariant]
    var body: some View {
        let review = VariantPreviewData.review(state: "accepted", variants: variants, chosen: "b")
        VStack(alignment: .leading, spacing: Space.m) {
            if let text = review.chosenText, let chosen = review.chosenVariant {
                Text(verbatim: text).font(.subheadline.weight(.semibold))
                ChosenVariantView(review: review, chosen: chosen)
            }
            ReviewUndoBar(offer: ReviewUndoOffer(taskID: review.taskID, until: Date().addingTimeInterval(ReviewUndo.window - 28), message: review.chosenText ?? ""))
        }
        .pageMargins().padding(.vertical, Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.canvas)
        .environment(AppModel())
    }
}

#Preview("Review mit Varianten, Light") { ReviewWithVariantsPreview(variants: VariantPreviewData.withPictures) }
#Preview("Review Textvarianten, Dark, klein") { ReviewWithVariantsPreview(variants: VariantPreviewData.textOnly).preferredColorScheme(.dark) }
#Preview("Review mit Varianten, accessibility5") { ReviewWithVariantsPreview(variants: VariantPreviewData.withPictures).dynamicTypeSize(.accessibility5) }
#Preview("Gewählt + Rückgängig, Light") { ChosenPreview(variants: VariantPreviewData.withPictures) }
#Preview("Gewählt + Rückgängig, Dark") { ChosenPreview(variants: VariantPreviewData.textOnly).preferredColorScheme(.dark) }
#Preview("Gewählt + Rückgängig, accessibility5") { ChosenPreview(variants: VariantPreviewData.withPictures).dynamicTypeSize(.accessibility5) }

private struct VariantsPreview: View {
    let variants: [ReviewVariant]
    var body: some View {
        ScrollView {
            ReviewVariantsView(variants: variants, busy: false, choosingID: nil) { _ in }
                .pageMargins().padding(.vertical, Space.l)
        }
        .background(Color.canvas)
        .environment(AppModel())
    }
}

#Preview("Varianten mit Bild, Light") { VariantsPreview(variants: VariantPreviewData.withPictures) }
#Preview("Varianten Text, Dark, klein") { VariantsPreview(variants: VariantPreviewData.textOnly).preferredColorScheme(.dark) }
#Preview("Varianten lange Wörter, accessibility5") { VariantsPreview(variants: VariantPreviewData.longWords).dynamicTypeSize(.accessibility5) }
#endif
