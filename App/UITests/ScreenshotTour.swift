import XCTest

/// Local helper, not part of the regular suite: launches the app on a list of debug targets in several looks, scrolls
/// to the bottom and writes PNGs. Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT` (directory) and
/// `TODO_TOUR_PREFIX`; optional `TODO_TOUR_LOOKS` (e.g. `light-m,dark-m,light-ax`) and `TODO_TOUR_LANDSCAPE=1`.
final class ScreenshotTour: XCTestCase {
    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let out = env["TODO_TOUR_OUT"] else {
            throw XCTSkip("tour variables not set")
        }
        let prefix = env["TODO_TOUR_PREFIX"] ?? "tour"
        let looks = (env["TODO_TOUR_LOOKS"] ?? "light-m,dark-m,light-ax").split(separator: ",").map(String.init)
        let only = env["TODO_TOUR_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let targets: [(name: String, select: String, extra: [String: String])] = [
            ("today", "today", [:]),
            ("cc", "commandcenter", ["TODO_DEBUG_CC_MODE": "kanban"]),
            ("cclist", "commandcenter", ["TODO_DEBUG_CC_MODE": "list"]),
            ("ccempty", "cc:Website", ["TODO_DEBUG_CC_MODE": "kanban"]),
            ("project", "project:Umzug", [:]),
            ("website", "project:Website-Relaunch", [:]),
            ("board", "project:Vibecoding", ["TODO_DEBUG_BOARD": "1"]),
            ("task", "task:Angebote fuer Arbeitsplatte einholen", [:]),
            ("account", "account", [:]),
            ("search", "search", [:]),
            ("feed", "feed", [:]),
        ]
        if env["TODO_TOUR_LANDSCAPE"] == "1" { XCUIDevice.shared.orientation = .landscapeLeft }
        for look in looks {
            for t in targets where only == nil || only!.contains(t.name) {
                let app = XCUIApplication()
                app.launchEnvironment["TODO_DEBUG_SERVER"] = server
                app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
                app.launchEnvironment["TODO_DEBUG_SELECT"] = t.select
                for (k, v) in t.extra { app.launchEnvironment[k] = v }
                let dark = look.hasPrefix("dark")
                app.launchArguments += ["-AppleInterfaceStyle", dark ? "Dark" : "Light"]
                if look.hasSuffix("ax") {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
                } else {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
                }
                app.launch()
                Thread.sleep(forTimeInterval: 6)
                write(out, "\(prefix)-\(t.name)-\(look)-top")
                if env["TODO_TOUR_NOSCROLL"] != "1" {
                    for _ in 0..<10 { app.windows.firstMatch.swipeUp(velocity: .fast) }
                    Thread.sleep(forTimeInterval: 1)
                    write(out, "\(prefix)-\(t.name)-\(look)-bottom")
                }
                app.terminate()
            }
        }
    }

    private func write(_ dir: String, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
