import XCTest

/// Card 80738AEA: picture tour of project groups against a scratch backend (seed: TodoCore
/// `LiveProjectGroupsTests.testSeedGroupsTour`). Needs `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT` (directory),
/// skipped otherwise. Light: settings with groups and mandates, group editor, mandate editor with the server preview in both
/// modes (cancelled). Dark: the same, then real saves: a project joins the group "Kunden", the mandate switches to
/// "Alle außer …" and the row shows the new rule. File names: `<screen>-<hell|dunkel>.png`.
final class ProjectGroupsTour: XCTestCase {
    private var out = ""

    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let dir = env["TODO_TOUR_OUT"] else {
            throw XCTSkip("tour variables not set")
        }
        out = dir
        continueAfterFailure = false

        // A throw-away launch absorbs the 401 the first request after an install may answer.
        let warm = XCUIApplication()
        warm.launchEnvironment["TODO_DEBUG_SERVER"] = server
        warm.launchEnvironment["TODO_DEBUG_TOKEN"] = token
        warm.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
        warm.launch()
        Thread.sleep(forTimeInterval: 6)
        warm.terminate()

        for look in ["hell", "dunkel"] {
            let dark = look == "dunkel"
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = "account"
            app.launchArguments += ["-appearance.colorScheme", dark ? "dark" : "light"]
            app.launch()

            // Settings: groups and the mandate with its rule.
            let kunden = app.buttons["group.row.Kunden"]
            XCTAssertTrue(reveal(app, kunden), "group row (\(look))")
            XCTAssertTrue(app.buttons["group.row.Privat"].exists, "second group (\(look))")
            XCTAssertTrue(app.buttons["mandate.row.Brain"].exists, "mandate row below the groups (\(look))")
            XCTAssertTrue(app.buttons["mandate.row.Brain"].label.contains("Gruppen: Kunden"), app.buttons["mandate.row.Brain"].label)
            shot("einstellungen-gruppen-\(look)")

            // Group editor: name and members.
            kunden.tap()
            XCTAssertTrue(app.textFields["group.name"].waitForExistence(timeout: 10), "group editor (\(look))")
            XCTAssertEqual(app.textFields["group.name"].value as? String, "Kunden")
            let garten = app.switches["group.member.Garten"]
            XCTAssertTrue(garten.waitForExistence(timeout: 5))
            if dark {
                flip(garten)
                XCTAssertEqual(app.switches["group.member.Garten"].value as? String, "1")
                shot("gruppe-bearbeiten-\(look)")
                app.buttons["group.save"].tap()
                XCTAssertTrue(waitGone(app.textFields["group.name"]), "editor closes after saving")
                XCTAssertTrue(reveal(app, app.buttons["group.row.Kunden"]))
                XCTAssertTrue(app.buttons["group.row.Kunden"].label.contains("3"), "the group now has three projects: \(app.buttons["group.row.Kunden"].label)")
            } else {
                shot("gruppe-bearbeiten-\(look)")
                app.buttons["sheet.cancel"].tap()
                XCTAssertTrue(waitGone(app.textFields["group.name"]))
            }

            // Mandate editor: explicit project plus group, preview from the server; then "all except".
            let mandate = app.buttons["mandate.row.Brain"]
            XCTAssertTrue(reveal(app, mandate), "mandate row (\(look))")
            mandate.tap()
            let count = app.staticTexts["selection.preview.count"]
            XCTAssertTrue(count.waitForExistence(timeout: 15), "server preview (\(look))")
            // Umzug + Kunden (Website-Relaunch, Steuer 2026; in the dark run also Garten).
            XCTAssertTrue(count.label.contains(dark ? "4" : "3"), count.label)
            XCTAssertEqual(app.switches["selection.group.Kunden"].value as? String, "1", "the group rule is loaded, not the effective list")
            XCTAssertEqual(app.switches["selection.project.Umzug"].value as? String, "1")
            shot("vollmacht-auswahl-\(look)")
            let web = app.switches["selection.project.Website-Relaunch"]
            for _ in 0..<6 where !web.exists { app.swipeUp() }
            XCTAssertEqual(web.value as? String, "0", "effective projects are not ticked as explicit ones")
            for _ in 0..<6 where !app.segmentedControls["selection.mode"].isHittable { app.swipeDown() }

            app.segmentedControls["selection.mode"].buttons["Alle außer …"].tap()
            XCTAssertTrue(app.switches["selection.group.Privat"].waitForExistence(timeout: 5), "excluded groups list (\(look))")
            flip(app.switches["selection.group.Privat"])
            // The count is gone while the preview is pending, so the predicate asks for it first.
            let changed = NSPredicate(format: "exists == true AND label CONTAINS %@", "Wirkt jetzt auf 3 Projekte")
            expectation(for: changed, evaluatedWith: app.staticTexts["selection.preview.count"])
            waitForExpectations(timeout: 15)  // Website-Relaunch, Kueche, Steuer 2026: "Privat" (Umzug, Garten) is out, the subproject Kueche is not in it
            shot("vollmacht-alle-ausser-\(look)")
            if dark {
                app.buttons["selection.save"].tap()
                XCTAssertTrue(waitGone(app.staticTexts["selection.preview.count"]), "editor closes after saving")
                let row = app.buttons["mandate.row.Brain"]
                XCTAssertTrue(reveal(app, row))
                let saved = NSPredicate(format: "label CONTAINS %@", "Alle außer 1")
                expectation(for: saved, evaluatedWith: row)
                waitForExpectations(timeout: 15)
                shot("vollmacht-gespeichert-\(look)")
            } else {
                app.buttons["sheet.cancel"].tap()
                XCTAssertTrue(waitGone(app.staticTexts["selection.preview.count"]))
            }
            app.terminate()
        }
    }

    /// The write paths through the real UI against the same backend (runs after `testTour`): create, rename and delete a group;
    /// revoke a mandate and give it again unchanged; create a project that joins a group right away; take it out again in the
    /// project's "Mehr" menu. Every result is read back from the server by the settings screen.
    func testWrites() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let dir = env["TODO_TOUR_OUT"] else {
            throw XCTSkip("tour variables not set")
        }
        out = dir
        continueAfterFailure = false
        func launch(_ select: String) -> XCUIApplication {
            let app = XCUIApplication()
            app.launchEnvironment["TODO_DEBUG_SERVER"] = server
            app.launchEnvironment["TODO_DEBUG_TOKEN"] = token
            app.launchEnvironment["TODO_DEBUG_SELECT"] = select
            app.launchArguments += ["-appearance.colorScheme", "light"]
            app.launch()
            return app
        }

        var app = launch("account")
        // Create.
        let new = app.buttons["group.new"]
        XCTAssertTrue(reveal(app, new), "create button")
        new.tap()
        let name = app.textFields["group.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["group.save"].isEnabled, "no name yet")
        name.tap(); name.typeText("Verein")
        app.buttons["group.save"].tap()
        let verein = app.buttons["group.row.Verein"]
        XCTAssertTrue(verein.waitForExistence(timeout: 15), "the server lists the new group")
        // Rename.
        XCTAssertTrue(reveal(app, verein)); verein.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        name.typeText(" 2027")
        app.buttons["group.save"].tap()
        let renamed = app.buttons["group.row.Verein 2027"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 15), "renamed on the server")
        // Delete (with confirmation).
        XCTAssertTrue(reveal(app, renamed)); renamed.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let delete = app.buttons["Gruppe löschen"].firstMatch
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons.matching(identifier: "Gruppe löschen")
        XCTAssertTrue(confirm.element(boundBy: 0).waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(waitGone(app.buttons["group.row.Verein 2027"]), "deleted")

        // Revoke the mandate, then give it again without changing the selection.
        let mandate = app.buttons["mandate.row.Brain"]
        XCTAssertTrue(reveal(app, mandate))
        mandate.press(forDuration: 1.2)
        let revoke = app.buttons["Widerrufen"].firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 5), "context menu")
        revoke.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Widerrufen"), evaluatedWith: mandate)
        waitForExpectations(timeout: 15)
        shot("vollmacht-widerrufen-hell")
        mandate.tap()
        let save = app.buttons["selection.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        // "Sichern" waits for the preview of the shown selection.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 15)  // a revoked mandate can be given again unchanged
        save.tap()
        XCTAssertTrue(waitGone(app.buttons["selection.save"]))
        XCTAssertTrue(reveal(app, mandate))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Aktiv"), evaluatedWith: mandate)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(mandate.label.contains("Alle außer 1"), "the rule survived revoke and re-grant: \(mandate.label)")
        app.terminate()

        // New project that joins "Kunden" right away.
        app = launch("projects")
        let add = app.buttons["Projekt hinzufügen"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 30), "add project")
        for _ in 0..<10 where !add.isHittable { drag(app) }
        add.tap()
        let projectName = app.textFields["project.new.name"]
        XCTAssertTrue(projectName.waitForExistence(timeout: 10))
        projectName.tap(); projectName.typeText("Neukunde")
        let inKunden = app.switches["project.group.Kunden"]
        XCTAssertTrue(inKunden.waitForExistence(timeout: 15), "the sheet offers the groups")
        if !inKunden.isHittable { app.swipeUp() }
        flip(inKunden)
        XCTAssertEqual(inKunden.value as? String, "1")
        shot("projekt-neu-gruppen-hell")
        app.buttons["project.new.save"].tap()
        XCTAssertTrue(waitGone(app.textFields["project.new.name"]))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 8), "no 'groups could not be set' notice")
        app.terminate()

        // The project's menu shows the group from the server; take it out and read it again.
        app = launch("project:Neukunde")
        func openGroups() {
            let more = app.buttons["Mehr"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 30), "project menu")
            more.tap()
            let entry = app.buttons["Gruppen"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "menu entry")
            entry.tap()
            XCTAssertTrue(app.switches["project.group.Kunden"].waitForExistence(timeout: 15))
        }
        openGroups()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: app.switches["project.group.Kunden"])
        waitForExpectations(timeout: 15)
        XCTAssertEqual(app.switches["project.group.Privat"].value as? String, "0")
        shot("projekt-gruppen-hell")
        flip(app.switches["project.group.Kunden"])
        app.buttons["project.groups.save"].tap()
        XCTAssertTrue(waitGone(app.switches["project.group.Kunden"]))
        openGroups()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.switches["project.group.Kunden"].value as? String, "0", "saved on the server")
        app.terminate()
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: 10) == .completed
    }

    /// The element's center is the label; the real switch sits at the trailing edge of the row.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Scrolls the settings list with deterministic drags until the element sits in the upper part of the screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        if !element.waitForExistence(timeout: 30) {
            for _ in 0..<25 where !element.exists { drag(app) }
        }
        var n = 0
        let height = app.windows.firstMatch.frame.height
        while element.exists && (!element.isHittable || element.frame.maxY > height * 0.6) && n < 40 { drag(app); n += 1 }
        return element.exists && element.isHittable
    }

    private func drag(_ app: XCUIApplication) {
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
