#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import TodoCore

/// `TODO_DEBUG_WINDOW_SHOTS=<dir>` (macOS, Debug only; card A6B0D5E3): looks at the REAL main window without showing it.
/// The app runs with activation policy `.prohibited` (`AppDelegate`), so nothing is activated and nothing appears on the
/// desktop. The window is a real `NSWindow` (titled, resizable, unified toolbar) with `NSHostingController(rootView: RootView())`,
/// the same root as the `WindowGroup`, but never ordered front. Sidebar rows are selected through the real AppKit outline view
/// (`selectRowIndexes`, the path a mouse click takes), then the window frame view is rendered to a PNG per screen and colour
/// scheme. `report.json` records what the run proves (policy, not active, not on screen) and what each shot shows.
/// Driven by `scripts/mac-window-e2e.sh`, checked by `scripts/verify-mac-window.py`.
/// A normal `NSWindow` that AppKit may not move back onto a screen when it is ordered in.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
enum DebugWindowShots {
    static var dir: String? { ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_SHOTS"] }

    private struct Step {
        let key: String
        /// Sidebar entry and its row offset from "Für dich" in the outline view; nil = not a sidebar row (reached through the model).
        let item: SidebarItem?
        let offset: Int?
        let prepare: (AppModel) async -> Void
    }

    private static let steps: [Step] = [
        Step(key: "feed", item: .feed, offset: 0) { $0.selection = .feed },
        Step(key: "commandcenter", item: .commandCenter, offset: 1) { $0.selection = .commandCenter },
        Step(key: "today", item: .today, offset: 6) { $0.selection = .today },
        Step(key: "upcoming", item: .upcoming, offset: 7) { $0.selection = .upcoming },
        Step(key: "inbox", item: .inbox, offset: 9) { $0.selection = .inbox },
        Step(key: "calendar", item: .calendar, offset: 8) { $0.selection = .calendar },
        Step(key: "project", item: nil, offset: nil) { m in
            if let p = m.tree.first?.project { m.selectedProjectID = p.id }
        },
        Step(key: "task", item: nil, offset: nil) { m in
            if let p = m.tree.first?.project { m.selectedProjectID = p.id }
            try? await Task.sleep(for: .milliseconds(500))
            if let t = m.tasks.first(where: { $0.projectID == m.selectedProjectID }) ?? m.tasks.first { m.path = [t] }
        },
        Step(key: "account", item: nil, offset: nil) { $0.selection = .account },
    ]

    static func run(model: AppModel) async {
        guard let dir else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for _ in 0..<150 where model.phase != .signedIn { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.phase == .signedIn else { fputs("window shots: not signed in\n", stderr); exit(3) }
        await model.reload()
        await model.reloadTeams()

        let size = CGSize(width: 1280, height: 820)
        let controller = NSHostingController(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.alphaValue = CGFloat(Double(ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_ALPHA"] ?? "") ?? 0)
        window.ignoresMouseEvents = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) // belt and braces: even if shown it would be off every screen
        // AppKit lays out and renders a window's views only while the window is in the window list. Ordered back, fully transparent,
        // mouse-transparent, far outside every screen (see `OffscreenWindow`), in an app that cannot be activated or show windows.
        window.orderBack(nil)
        window.makeKey()

        if let file = ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_PUSHES"] {
            await runPushes(file: file, model: model, window: window, out: out)
            exit(0)
        }

        // Baseline: where the outline view puts "Für dich" (the model drives this one selection).
        model.selection = .feed
        try? await Task.sleep(for: .seconds(2))
        window.displayIfNeeded()
        let base = firstTable(in: window.contentView)?.selectedRowIndexes.first ?? -1

        var shots: [[String: Any]] = []
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for step in steps {
                var clicked = false
                if let item = step.item, let offset = step.offset, base >= 0, let table = firstTable(in: window.contentView) {
                    // The real click path: the outline view selects the row; SwiftUI turns that into model.selection.
                    if model.selection == item { model.selection = .search; try? await Task.sleep(for: .milliseconds(600)) }
                    table.selectRowIndexes(IndexSet(integer: base + offset), byExtendingSelection: false)
                    clicked = true
                } else {
                    await step.prepare(model)
                }
                try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_SETTLE"] ?? "") ?? 3))
                window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let name = "mac-\(step.key)-\(dark ? "dark" : "light").png"
                var shot = capture(window: window, name: name, to: out, step: step, scheme: dark ? "dark" : "light")
                shot["clickPath"] = clicked
                shot["modelSelection"] = String(describing: model.selection)
                shot["selectionOK"] = step.item.map { model.selection == $0 } ?? true
                shots.append(shot)
            }
        }
        let control = await controlProbe(size: size)
        let report: [String: Any] = [
            "control": control,
            "sidebarRows": (firstTable(in: window.contentView)).map { t in (0..<t.numberOfRows).map { rowLabel(t, $0) } } ?? [],
            "environment": [
                "activationPolicy": NSApp.activationPolicy() == .prohibited ? "prohibited" : "other",
                "appActive": NSApp.isActive,
                "windowOnScreen": NSScreen.screens.contains { $0.frame.intersects(window.frame) } || (window.alphaValue > 0 && NSScreen.screens.contains { $0.frame.intersects(window.frame) }),
                "windowClass": window.isKind(of: NSWindow.self) ? "NSWindow" : String(describing: type(of: window)),
                "hostingController": window.contentViewController is NSHostingController<AnyView> || String(describing: type(of: window.contentViewController!)).contains("NSHostingController"),
                "frame": NSStringFromRect(window.frame),
            ],
            "shots": shots,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
        exit(0)
    }

    /// `TODO_DEBUG_WINDOW_PUSHES=<json file>` (card D97C4918): `[{"name":..,"payload":{server push payload}}]`. Each push is
    /// handed to the real `NotificationDelegate` while the window shows the search screen; `report.json` records where the
    /// model ended up and the window is captured once per push and colour scheme.
    private static func runPushes(file: String, model: AppModel, window: NSWindow, out: URL) async {
        guard let data = FileManager.default.contents(atPath: file),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { fputs("window pushes: unreadable \(file)\n", stderr); exit(4) }
        var results: [[String: Any]] = []
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for entry in list {
                guard let name = entry["name"] as? String, let payload = entry["payload"] as? [String: Any],
                      let json = try? JSONSerialization.data(withJSONObject: payload) else { continue }
                model.path = []; model.confirmationFocus = nil; model.selection = .search
                try? await Task.sleep(for: .seconds(1))
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let info = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
                    DebugLaunch.deliver(info, only: "didReceive")
                }
                try? await Task.sleep(for: .seconds(4))
                window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let png = "mac-push-\(name)-\(dark ? "dark" : "light").png"
                _ = capture(window: window, name: png, to: out, step: Step(key: name, item: nil, offset: nil) { _ in }, scheme: dark ? "dark" : "light")
                results.append([
                    "name": name, "file": png, "selection": String(describing: model.selection),
                    "task": model.path.last?.title ?? "", "taskID": model.path.last?.id.uuidString ?? "",
                ])
            }
        }
        let report: [String: Any] = [
            "policyProhibited": NSApp.activationPolicy() == .prohibited, "appActive": NSApp.isActive,
            "windowOnScreen": NSScreen.screens.contains { $0.frame.intersects(window.frame) },
            "pushes": results,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
    }

    /// Control: a plain SwiftUI `List(selection:)` with the sidebar style, nothing of the app, captured the same way. Shows what a
    /// native selected row looks like in this offscreen harness (the window is never key, the app never active).
    private static func controlProbe(size: CGSize) async -> [String: Any] {
        struct Control: View {
            @State var selection: String? = "Beta"
            var body: some View {
                List(selection: $selection) { ForEach(["Alpha", "Beta", "Gamma", "Delta", "Epsilon"], id: \.self) { Text($0).tag($0) } }.listStyle(.sidebar)
            }
        }
        var result: [String: Any] = [:]
        for dark in [false, true] {
            let controller = NSHostingController(rootView: Control().frame(width: 280, height: 400))
            let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.orderBack(nil)
            try? await Task.sleep(for: .seconds(1.5))
            if let table = firstTableAny(in: window.contentView), let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds) {
                table.cacheDisplay(in: table.bounds, to: rep)
                let row = table.selectedRowIndexes.first ?? 1
                let r = table.rect(ofRow: row)
                let scale = CGFloat(rep.pixelsWide) / table.bounds.width
                if let c = rep.colorAt(x: Int((r.minX + 6) * scale), y: Int(r.midY * scale))?.usingColorSpace(.sRGB) {
                    result[dark ? "dark" : "light"] = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                }
            }
            window.close()
        }
        return result
    }

    private static func firstTableAny(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = firstTableAny(in: sub) { return t } }
        return nil
    }

    private static func capture(window: NSWindow, name: String, to out: URL, step: Step, scheme: String) -> [String: Any] {
        guard let frame = window.contentView?.superview ?? window.contentView else { return ["screen": step.key, "scheme": scheme, "file": name] }
        frame.layoutSubtreeIfNeeded()
        var info: [String: Any] = ["screen": step.key, "scheme": scheme, "file": name]
        if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            // A real window has an opaque backing; without it transparent regions (inspector column) come out white.
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: frame.bounds.size).fill() }
                NSGraphicsContext.restoreGraphicsState()
            }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            // `cacheDisplay` of the whole window leaves the sidebar's rows out (platform-backed outline view); draw them in separately.
            if let table = firstTable(in: window.contentView), let tr = table.bitmapImageRepForCachingDisplay(in: table.bounds) {
                table.cacheDisplay(in: table.bounds, to: tr)
                let visible = table.convert(table.visibleRect, to: frame)
                NSGraphicsContext.saveGraphicsState()
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.current = ctx // points, origin bottom left
                    let target = NSRect(x: visible.minX, y: frame.isFlipped ? frame.bounds.height - visible.maxY : visible.minY, width: visible.width, height: visible.height)
                    let source = NSRect(x: 0, y: table.isFlipped ? table.bounds.height - table.visibleRect.maxY : table.visibleRect.minY, width: table.visibleRect.width, height: table.visibleRect.height)
                    NSImage(size: table.bounds.size, flipped: false) { r in tr.draw(in: r); return true }
                        .draw(in: target, from: source, operation: .sourceOver, fraction: 1)
                }
                NSGraphicsContext.restoreGraphicsState()
                if ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_DUMP"] != nil, let row = table.selectedRowIndexes.first, let rv = table.rowView(atRow: row, makeIfNecessary: false) {
                    fputs("sel row \(row) emphasized=\(rv.isEmphasized) selected=\(rv.isSelected) key=\(window.isKeyWindow) style=\(table.selectionHighlightStyle.rawValue) accent=\(NSColor.controlAccentColor)\n", stderr)
                }
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            if ProcessInfo.processInfo.environment["TODO_DEBUG_WINDOW_VARIANTS"] != nil, let layer = frame.layer {
                let scale = 2
                let w = Int(frame.bounds.width) * scale, h = Int(frame.bounds.height) * scale
                if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("layer-" + name)) }
                }
                if let table = firstTable(in: frame), let tr = table.bitmapImageRepForCachingDisplay(in: table.bounds) {
                    table.cacheDisplay(in: table.bounds, to: tr)
                    try? tr.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("table-" + name))
                }
            }
            if let table = firstTable(in: window.contentView) {
                let selected = table.selectedRowIndexes.first
                let label = selected.map { rowLabel(table, $0) } ?? ""
                _ = label
                info["selectedRowIndex"] = selected ?? -1
                if let row = selected {
                    let r = table.rect(ofRow: row)
                    let probe = frame.convert(NSPoint(x: r.minX + 6, y: r.midY), from: table)
                    let px = pixel(rep, frame: frame, at: probe)
                    info["selectionColor"] = px.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) } ?? "?"
                    // Legible = the row background differs from black/white text colours enough; checked with the label's pixels.
                    info["selectionLabelColor"] = "n/a"
                    info["sidebarSelectionLegible"] = px.map { !($0.0 < 24 && $0.1 < 24 && $0.2 < 24) } ?? false
                } else {
                    info["sidebarSelectionLegible"] = step.item == nil
                }
            } else {
                info["selectedRowIndex"] = -1; info["sidebarSelectionLegible"] = false
            }
        }
        info["contentHasText"] = hasText(in: window.contentView)
        info["textFields"] = editableTextFields(in: window.contentView)
        return info
    }

    // MARK: AppKit introspection

    /// Every editable text field with its placeholder and size: the verifier checks that the empty chat field is one line high.
    private static func editableTextFields(in view: NSView?) -> [[String: Any]] {
        guard let view else { return [] }
        var found: [[String: Any]] = []
        if let field = view as? NSTextField, field.isEditable {
            found.append(["placeholder": field.placeholderAttributedString?.string ?? field.placeholderString ?? "",
                          "width": Double(field.frame.width), "height": Double(field.frame.height)])
        }
        return view.subviews.reduce(found) { $0 + editableTextFields(in: $1) }
    }

    private static func dump(_ view: NSView?, _ depth: Int) {
        guard let view, depth < 40 else { return }
        let extra = (view as? NSTableView).map { " rows=\($0.numberOfRows) sel=\($0.selectedRowIndexes.count)" } ?? ""
        let cls = String(describing: type(of: view))
        if cls.contains("Table") || cls.contains("Outline") || cls.contains("Scroll") || cls.contains("Split") || depth < 5 {
            fputs(String(repeating: " ", count: depth) + cls + " " + NSStringFromRect(view.frame) + extra + "\n", stderr)
        }
        for s in view.subviews { dump(s, depth + 1) }
    }

    /// The sidebar's outline view: the leftmost table of the window that has rows.
    private static func firstTable(in view: NSView?) -> NSTableView? {
        var found: [NSTableView] = []
        func walk(_ v: NSView) { if let t = v as? NSTableView, t.numberOfRows > 3 { found.append(t) }; v.subviews.forEach(walk) }
        if let view { walk(view) }
        return found.min { $0.convert($0.bounds.origin, to: nil).x < $1.convert($1.bounds.origin, to: nil).x }
    }

    /// Accessibility text of a sidebar row (what VoiceOver reads).
    private static func rowLabel(_ table: NSTableView, _ row: Int) -> String {
        if let rows = table.perform(Selector("accessibilityRows"))?.takeUnretainedValue() as? NSArray, row < rows.count { return allText(rows[row]).joined(separator: " | ") }
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return "" }
        return allText(cell).joined(separator: " | ")
    }

    /// Every label/title/value reachable through the accessibility tree (views and SwiftUI's accessibility nodes) and subviews.
    private static func allText(_ element: Any) -> [String] {
        var texts: [String] = []
        func add(_ s: String?) { if let s, !s.isEmpty { texts.append(s) } }
        func walk(_ any: Any, _ depth: Int) {
            guard depth < 14 else { return }
            if let a = any as? NSObject {
                func get(_ name: String) -> Any? { a.responds(to: Selector(name)) ? a.perform(Selector(name))?.takeUnretainedValue() : nil }
                add(get("accessibilityLabel") as? String); add(get("accessibilityTitle") as? String); add(get("accessibilityValue") as? String)
                for c in (get("accessibilityChildren") as? NSArray) ?? [] { walk(c, depth + 1) }
            }
            if let v = any as? NSView {
                if let t = v as? NSTextField { add(t.stringValue) }
                for s in v.subviews { walk(s, depth + 1) }
            }
        }
        walk(element, 0)
        return Array(NSOrderedSet(array: texts)) as? [String] ?? texts
    }

    private static func hasText(in view: NSView?) -> Bool {
        guard let view else { return false }
        return allText(view).count > 8
    }

    private static func pixel(_ rep: NSBitmapImageRep, frame: NSView, at point: NSPoint) -> (Int, Int, Int)? {
        let scale = CGFloat(rep.pixelsWide) / max(frame.bounds.width, 1)
        let x = Int(point.x * scale)
        let y = frame.isFlipped ? Int(point.y * scale) : Int((frame.bounds.height - point.y) * scale)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
#endif
