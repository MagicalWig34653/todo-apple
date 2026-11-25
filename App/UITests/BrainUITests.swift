import XCTest

/// HTTP side of the brain tests: a paired Mac runner (device token) and the account's own session, plain `URLSession`
/// against the real backend, no mocks. Blocking, because XCUITest calls are synchronous too.
final class BrainBackend: @unchecked Sendable {
    let base: URL
    let sessionToken: String
    private(set) var runnerToken = ""
    private(set) var deviceID = ""

    init(base: URL, sessionToken: String) { self.base = base; self.sessionToken = sessionToken }

    struct Job { let id: String; let generation: Int; let messageID: String; let attachmentID: String }

    @discardableResult
    func call(_ method: String, _ path: String, bearer: String, query: [String: String] = [:], json: [String: Any]? = nil,
              body: Data? = nil, contentType: String? = nil) -> (data: Data, status: Int) {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        } else if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else if method == "POST" || method == "PUT" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        let done = DispatchSemaphore(value: 0)
        var result: (Data, Int) = (Data(), -1)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? -1)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

    /// Pairs a runner device once per test process (one-time code from the session, exchanged for the device token).
    func pairRunnerIfNeeded() {
        guard runnerToken.isEmpty else { return }
        let code = object(call("POST", "v1/agents/devices", bearer: sessionToken, json: ["label": "UI-Test-Mac"]).data)
        let paired = object(call("POST", "v1/runner/pair", bearer: "", json: ["code": code["code"] as? String ?? ""]).data)
        runnerToken = paired["token"] as? String ?? ""
        deviceID = paired["deviceID"] as? String ?? ""
    }

    /// The runner reports "sprache" (valid for 90 s) and the owner has not switched it off.
    func makeReachable() {
        pairRunnerIfNeeded()
        call("PUT", "v1/agents/devices/\(deviceID)/capabilities", bearer: sessionToken, json: ["disabled": [String]()])
        call("POST", "v1/runner/voice/heartbeat", bearer: runnerToken, json: ["capabilities": ["sprache"]])
    }

    /// The owner switches "sprache" off: the server answers voice messages with "nur per Text erreichbar".
    func makeUnreachable() {
        pairRunnerIfNeeded()
        call("PUT", "v1/agents/devices/\(deviceID)/capabilities", bearer: sessionToken, json: ["disabled": ["sprache"]])
    }

    func claim() -> Job? {
        let r = call("POST", "v1/runner/voice/claim", bearer: runnerToken)
        guard r.status == 200 else { return nil }
        let o = object(r.data)
        return Job(id: o["id"] as? String ?? "", generation: o["generation"] as? Int ?? 0,
                   messageID: o["messageID"] as? String ?? "", attachmentID: o["attachmentID"] as? String ?? "")
    }

    func audio(of job: Job) -> Data {
        call("GET", "v1/runner/voice/jobs/\(job.id)/audio", bearer: runnerToken, query: ["generation": String(job.generation)]).data
    }

    func answer(_ job: Job, replyAudio: Data, transcript: String, replyText: String) {
        let up = call("PUT", "v1/runner/voice/jobs/\(job.id)/reply-audio", bearer: runnerToken, query: ["generation": String(job.generation)],
                      body: replyAudio, contentType: "audio/mp4")
        XCTAssertEqual(up.status, 200, String(decoding: up.data, as: UTF8.self))
        let done = call("POST", "v1/runner/voice/jobs/\(job.id)/result", bearer: runnerToken,
                        json: ["generation": job.generation, "transcript": transcript, "replyText": replyText])
        XCTAssertEqual(done.status, 200, String(decoding: done.data, as: UTF8.self))
    }
}

/// Voice messages in the app against the real native backend: consent, recording (a prepared real M4A stands in for the
/// microphone, which the simulator lacks), upload, `voice_in`, and a runner simulated through `/v1/runner/voice/*` that answers.
/// Needs `TEST_RUNNER_TODO_UITEST_SERVER` / `_TOKEN` like the other UI tests. Optional `TEST_RUNNER_TODO_UITEST_SHOTS=<dir>`
/// writes screenshots. Real microphone capture is only checkable on a device.
final class BrainUITests: XCTestCase {
    private var app: XCUIApplication!
    private var backend: BrainBackend!
    private static var sharedBackend: BrainBackend?
    private var shotsDir: String?

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["TODO_UITEST_SERVER"], let token = env["TODO_UITEST_TOKEN"], let base = URL(string: server) else {
            throw XCTSkip("TODO_UITEST_SERVER / TODO_UITEST_TOKEN not set")
        }
        if Self.sharedBackend == nil { Self.sharedBackend = BrainBackend(base: base, sessionToken: token) }
        backend = Self.sharedBackend
        shotsDir = env["TODO_UITEST_SHOTS"]
    }

    // MARK: Helpers

    private func launch(consent: String, select: String = "brain", look: String = "light-m", extra: [String: String] = [:]) {
        let env = ProcessInfo.processInfo.environment
        app = XCUIApplication()
        app.launchEnvironment["TODO_DEBUG_SERVER"] = env["TODO_UITEST_SERVER"]
        app.launchEnvironment["TODO_DEBUG_TOKEN"] = env["TODO_UITEST_TOKEN"]
        app.launchEnvironment["TODO_DEBUG_SELECT"] = select
        app.launchEnvironment["TODO_DEBUG_NOW"] = "12:00"
        app.launchEnvironment["TODO_DEBUG_VOICE_FILE"] = Self.fixtures.appending(path: "voice-sample.m4a").path
        app.launchEnvironment["TODO_DEBUG_VOICE_MUTE"] = "1"
        app.launchEnvironment["TODO_DEBUG_VOICE_CONSENT"] = consent
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launchArguments += ["-AppleInterfaceStyle", look.hasPrefix("dark") ? "Dark" : "Light"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                look.hasSuffix("ax") ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private var mic: XCUIElement { app.buttons["brain.mic"] }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let shotsDir { try? png.write(to: URL(fileURLWithPath: "\(shotsDir)/\(name).png")) }
    }

    /// Waits for the runner API to hand out a job (the app posted `voice_in` a moment ago).
    private func claimJob(timeout: TimeInterval = 20) -> BrainBackend.Job? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            backend.makeReachable()  // keeps the 90 s heartbeat fresh
            if let job = backend.claim() { return job }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    // MARK: Tests

    /// Consent first, then hold to record, upload, processing state, the runner answers, text and audio show up.
    func test1_ConsentRecordSendAndAnswer() throws {
        backend.makeReachable()
        launch(consent: "off")
        XCTAssertTrue(mic.waitForExistence(timeout: 25), "microphone button")
        shot("t16-brain-empty")

        // First use: the press opens the consent dialog instead of recording.
        mic.press(forDuration: 0.5)
        let accept = app.buttons["voice.consent.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5), "consent dialog")
        XCTAssertTrue(app.staticTexts["Mikrofon"].exists)
        XCTAssertTrue(app.staticTexts["Lokal verarbeitet"].exists)
        shot("t16-consent")
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        let mineBefore = app.descendants(matching: .any).matching(identifier: "brain.message.mine").count
        XCTAssertFalse(el("brain.uploading").exists, "nothing was recorded by the first press")

        // Hold the microphone: the prepared recording is uploaded and posted as voice_in.
        mic.press(forDuration: 2.0)
        XCTAssertTrue(el("brain.processing").waitForExistence(timeout: 15), "waiting for the brain")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "brain.message.mine").count, mineBefore + 1, "exactly one new recording")
        shot("t16-processing")

        // The runner (simulated over the real runner API) receives exactly the uploaded bytes and answers.
        let job = try XCTUnwrap(claimJob(), "voice job for the runner")
        let sample = try Data(contentsOf: Self.fixtures.appending(path: "voice-sample.m4a"))
        XCTAssertEqual(backend.audio(of: job), sample, "the runner hears what the app recorded")
        let reply = try Data(contentsOf: Self.fixtures.appending(path: "voice-reply.m4a"))
        backend.answer(job, replyAudio: reply, transcript: "Hallo Brain, was steht heute an?", replyText: "Heute stehen zwei Aufgaben an.")

        // The open screen picks it up by itself (polling, no pull needed). The thread of the shared test account keeps the
        // answers of earlier runs, so the fixed texts below may already be on screen: the waiting state is what tells that
        // THIS answer has arrived ("processing" goes away when a later message of the brain exists).
        XCTAssertTrue(el("brain.processing").waitForNonExistence(timeout: 20), "answer arrived (waiting state gone)")
        XCTAssertTrue(app.staticTexts["Heute stehen zwei Aufgaben an."].waitForExistence(timeout: 5), "answer text")
        XCTAssertTrue(app.staticTexts["Hallo Brain, was steht heute an?"].exists, "transcript of the recording")
        shot("t16-answer")

        // Play the answer (muted by the debug hook): download, then play; the button says "Anhalten" while it runs.
        // The server deletes the recording once it is processed (retention), so only the brain's answers carry a play
        // button now; the newest one sits at the bottom of the thread.
        let plays = app.buttons.matching(identifier: "brain.play")
        XCTAssertGreaterThanOrEqual(plays.count, 1, "play button of the answer")
        plays.element(boundBy: plays.count - 1).tap()
        XCTAssertTrue(app.buttons["Anhalten"].waitForExistence(timeout: 10), "playback started")
        shot("t16-playing")
        app.buttons["Anhalten"].tap()
        XCTAssertTrue(app.buttons["Antwort anhören"].waitForExistence(timeout: 5), "playback stopped")
    }

    /// Swiping left while holding discards the recording: nothing reaches the server.
    func test2_SwipeLeftCancelsRecording() throws {
        backend.makeReachable()
        launch(consent: "granted")
        XCTAssertTrue(mic.waitForExistence(timeout: 25))
        let before = app.descendants(matching: .any).matching(identifier: "brain.message.mine").count
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.5, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        XCTAssertTrue(el("brain.hint").waitForExistence(timeout: 5))
        XCTAssertEqual(el("brain.hint").label, "Aufnahme verworfen.")
        XCTAssertFalse(el("brain.uploading").exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "brain.message.mine").count, before)
        shot("t16-cancelled")
        XCTAssertNil(backend.claim(), "the server never got the recording")
    }

    /// Too short a press is not a recording either.
    func test3_ShortTapIsNotSent() throws {
        backend.makeReachable()
        launch(consent: "granted")
        XCTAssertTrue(mic.waitForExistence(timeout: 25))
        mic.tap()
        XCTAssertTrue(el("brain.hint").waitForExistence(timeout: 5))
        XCTAssertTrue(el("brain.hint").label.hasPrefix("Zu kurz"))
        XCTAssertNil(backend.claim())
    }

    /// No Mac with "sprache": the server answers at once with "Brain gerade nur per Text erreichbar."
    func test4_UnreachableShowsServerStatusLine() throws {
        backend.makeUnreachable()
        defer { backend.makeReachable() }
        launch(consent: "granted")
        XCTAssertTrue(mic.waitForExistence(timeout: 25))
        mic.press(forDuration: 2.0)
        let status = app.staticTexts["Brain gerade nur per Text erreichbar."]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "status line of the server")
        XCTAssertFalse(el("brain.processing").waitForExistence(timeout: 2), "no waiting state when the brain is not reachable")
        shot("t16-unreachable")
    }

    /// A text message goes through the same channel.
    func test5_TextMessage() throws {
        launch(consent: "granted")
        let field = el("brain.composer")
        XCTAssertTrue(field.waitForExistence(timeout: 25))
        field.tap()
        let text = "Hallo per Text \(Int(Date().timeIntervalSince1970) % 100000)"
        field.typeText(text)
        app.buttons["brain.send"].tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "text message in the thread")
    }

    /// Settings: consent can be revoked; the next recording asks again.
    func test6_RevokeConsentInSettings() throws {
        launch(consent: "granted", select: "account")
        let state = el("voice.settings.state")
        for _ in 0..<12 where !state.exists || !state.isHittable { app.swipeUp() }
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let revoke = app.buttons["voice.settings.revoke"]
        for _ in 0..<4 where !revoke.isHittable { app.swipeUp() }
        shot("t16-settings-granted")
        revoke.tap()
        let confirm = app.sheets.buttons["Einwilligung widerrufen"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons["voice.settings.grant"].waitForExistence(timeout: 5), "consent is off")
        shot("t16-settings-revoked")
    }

    /// Looks for the report: dark and accessibility size with a populated thread.
    func test7_Looks() throws {
        for look in ["dark-m", "light-ax", "dark-ax"] {
            launch(consent: "granted", look: look)
            XCTAssertTrue(mic.waitForExistence(timeout: 25), look)
            Thread.sleep(forTimeInterval: 3)  // thread loaded; long lazy thread at large text sizes shows only its tail
            shot("t16-thread-\(look)")
            app.terminate()
        }
        launch(consent: "granted", look: "dark-m", extra: ["TODO_DEBUG_VOICE_AUTOSTART": "1"])
        XCTAssertTrue(el("brain.recording").waitForExistence(timeout: 25))
        shot("t16-recording-dark-m")
        app.terminate()
        launch(consent: "granted", look: "light-ax", extra: ["TODO_DEBUG_VOICE_AUTOSTART": "1"])
        XCTAssertTrue(el("brain.recording").waitForExistence(timeout: 25))
        shot("t16-recording-light-ax")
        app.terminate()
        launch(consent: "off", look: "light-ax")
        XCTAssertTrue(mic.waitForExistence(timeout: 25))
        mic.press(forDuration: 0.5)
        XCTAssertTrue(app.buttons["voice.consent.accept"].waitForExistence(timeout: 5))
        shot("t16-consent-light-ax")
        app.terminate()
        launch(consent: "off", look: "dark-m")
        XCTAssertTrue(mic.waitForExistence(timeout: 25))
        mic.press(forDuration: 0.5)
        XCTAssertTrue(app.buttons["voice.consent.accept"].waitForExistence(timeout: 5))
        shot("t16-consent-dark-m")
    }

    /// Entry on the iPhone: the brain button sits on "Für dich".
    func test8_EntryFromFeed() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone entry")
        launch(consent: "granted", select: "feed")
        let entry = app.buttons["feed.brain"]
        XCTAssertTrue(entry.waitForExistence(timeout: 25), "brain button on Für dich")
        shot("t16-entry-feed")
        entry.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "brain screen opened")
    }
}
