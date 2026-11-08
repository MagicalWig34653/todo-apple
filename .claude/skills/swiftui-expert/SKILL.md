---
name: swiftui-expert
description: Use when writing, reviewing or refactoring SwiftUI interfaces in this app (iOS/macOS) - layout, adaptivity, accessibility, state and view composition. Nutzen beim Schreiben oder Prüfen von SwiftUI-Oberflächen (Layout, Barrierefreiheit, State, View-Struktur).
---

# SwiftUI Expert (Todolino)

Gekürzte Adaption von AvdLee/SwiftUI-Agent-Skill (MIT, siehe `LICENSE-AvdLee.md`). Enthalten sind nur die Regeln, die hier gebraucht werden; Trace-/Profiling-Workflows und Themen wie Liquid Glass oder Foldables sind bewusst nicht übernommen.

## Operating Rules

- Treat each `View` type as an invalidation boundary: give it only the data it reads and keep frequently changing dependencies close to the smallest affected subtree
- Prefer native SwiftUI APIs over UIKit/AppKit bridging unless bridging is necessary
- Focus on correctness and performance; do not enforce specific architectures (MVVM, VIPER, etc.)
- Encourage separating business logic from views for testability without mandating how
- Follow Apple's Human Interface Guidelines (see `references/hig-kernregeln.md`)
- Present performance optimizations as suggestions, not requirements
- Use `#available` gating with sensible fallbacks for version-specific APIs
- For layout inputs, read the value nearest the SwiftUI view that consumes it; do not substitute process-global screen state

## Task Workflow

### Review existing SwiftUI code
- Read the code under review and identify which topics apply
- Flag deprecated APIs; replace hard-deprecated ones, flag soft-deprecated ones without rewriting them unless asked
- Check the topics below and validate `#available` gating and fallbacks
- For broad reviews, split into smaller focus areas and work through them one at a time

### Implement new SwiftUI feature
- Design data flow first: identify owned vs injected state
- Structure views for optimal diffing (extract subviews early)
- Apply correct animation patterns (implicit vs explicit, transitions)
- Use `Button` for all tappable elements; add accessibility grouping and labels
- Gate version-specific APIs with `#available` and provide fallbacks

## Topic Router

| Topic | Reference |
|-------|-----------|
| Resizable layout, safe areas, container ownership, layout performance | `references/layout-best-practices.md` |
| Accessibility (Dynamic Type, traits, grouping, custom controls) | `references/accessibility-patterns.md` |
| HIG core rules in short form | `references/hig-kernregeln.md` |

Other topics (state, lists, animation, navigation) have no reference file here; apply the Correctness Checklist and the Operating Rules.

## Correctness Checklist

These are hard rules -- violations are always bugs:

- [ ] `@State` properties are `private`
- [ ] `@Binding` only where a child modifies parent state
- [ ] Changing parent-owned inputs are not stored as `@State`/`@StateObject`; intentional state seeds are documented as one-time
- [ ] `@StateObject` for view-owned objects; `@ObservedObject` for injected
- [ ] iOS 17+: `@State` with `@Observable`; `@Bindable` for injected observables needing bindings
- [ ] `ForEach` uses stable identity (never `.indices`/`\.offset`; id outlives the view and isn't derived from mutable content)
- [ ] Constant number of views per `ForEach` element; `List` rows are unary
- [ ] No closures stored in custom `@Environment`/`@FocusedValue` keys
- [ ] Custom `@Entry` default values are stable (no `Model()`/`Date()`/`UUID()` expressions)
- [ ] SwiftUI display scale comes from `@Environment(\.displayScale)`, not global screen state
- [ ] Safe-area content does not double-apply `GeometryProxy.safeAreaInsets`
- [ ] `.animation(_:value:)` always includes the `value` parameter
- [ ] `@FocusState` properties are `private`
- [ ] Version-specific APIs are gated with `#available` and have sensible fallbacks
- [ ] Previews use self-contained mock data; no dependency on live services or network

## Projektregeln Todolino

Diese Regeln gelten zusätzlich und haben bei Konflikt Vorrang. Tokens stehen in `App/Shared/Theme.swift`; nur das Genannte existiert dort tatsächlich.

- **Tokens statt Zahlen**: `Space` (xxs 2, xs 4, s 8, m 12, l 16, xl 24, xxl 32, `page` 16, `pageRegular` 24, `readableMax` 680) und `Radius` (xs 4, s 8, m 12, l 18, xl 26). Keine freien Abstands- oder Radiuswerte; Farben aus dem Asset-Katalog (`Color.brand`, `.onBrand`, `.textSecondary`, `.canvas`, `.hairline` usw.), nie hartkodiert. Auf Marken-Flächen `Color.onBrand` statt `.white`.
- **Seitenränder und Lesebreite**: `.pageMargins()` (16, auf regular Breite 24) und `.readableWidth(_:)` (Standard `Space.readableMax`) für Seiten auf iPad/Mac.
- **Tap-Ziele**: `TapTarget.minimum` = 44 pt iOS, 28 pt macOS. Per `.tapTarget()` sicherstellen (skaliert mit Dynamic Type), kein negatives Padding als Ausgleich. Symbolspalten und Avatare mit `.scaledSquare(_:relativeTo:)` statt fester `frame(width:)`.
- **Keine festen Gerätebreiten** (`UIScreen`, `frame(width: 390)`). Statt `GeometryReader` wo möglich `containerRelativeFrame`. Für Umbrüche `ViewThatFits` oder `AdaptiveStack` (HStack, ab Accessibility-Textgrößen leading-ausgerichteter VStack).
- **Nutzertexte nie ungebremst**: lange Titel, Antworten, Kommentare mit `lineLimit` plus Truncation (bzw. bewusst `lineLimit(nil)` ab Accessibility-Größen) und `minimumScaleFactor` nur sparsam; mehrzeilige Eingaben mit `axis: .vertical` und `lineLimit(1...4)`.
- **Previews**: pro Ansicht mindestens light, dark und `.dynamicTypeSize(.accessibility5)` (Vorbild: `ThemeGallery` in Theme.swift mit `#Preview("Theme light" / "Theme dark" / "Theme accessibility5")`), mit lokalen Beispieldaten.
- **iPhone-Tabs-Falle**: Ab dem 6. Tab packt iOS die überzähligen in ein eigenes "Mehr" mit eigenem Navigationscontroller; das führte zu doppelten Zurück-Schaltflächen (docs/UI-AUDIT.md, behoben durch Suche im Browse-Tab). Höchstens 5 Tabs.
- **Kontrast und Textgröße**: Mindestkontrast 4.5:1 für Text (daher `Color.textSecondary` statt `.secondary`, `TextField(accessible:...)` für Platzhalter). Text muss bis 200 % bzw. Accessibility-Größen nutzbar bleiben (nichts abgeschnitten, keine überdeckenden FABs).
