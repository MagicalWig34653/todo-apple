import Foundation

// MARK: Live refresh (ADR 0022, contracts/live-refresh.yaml)
//
// The server only sends hints, never data: `GET /v1/sync/head` returns an opaque change token, `GET /v1/sync/wait`
// is a long poll that returns as soon as the token differs from `since`. The client then refetches what it shows.
// `LiveRefresh` runs exactly one loop per account, only while started and in the foreground, and degrades to
// head polling (no wait) or sync polling (no head) on older servers.

public struct LiveRefreshCapability: Codable, Sendable, Equatable {
    public var head: Bool
    public var wait: Bool
    public var stream: Bool
    public var pollSeconds: Int
    public var waitMaxSeconds: Int

    public init(head: Bool = true, wait: Bool = true, stream: Bool = false, pollSeconds: Int = 5, waitMaxSeconds: Int = 25) {
        self.head = head; self.wait = wait; self.stream = stream
        self.pollSeconds = pollSeconds; self.waitMaxSeconds = waitMaxSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        head = try c.decodeIfPresent(Bool.self, forKey: .head) ?? true
        wait = try c.decodeIfPresent(Bool.self, forKey: .wait) ?? false
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        pollSeconds = max(1, try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 5)
        waitMaxSeconds = max(1, try c.decodeIfPresent(Int.self, forKey: .waitMaxSeconds) ?? 25)
    }
}

public struct LiveHead: Codable, Sendable, Equatable {
    public let cursor: String
    public let token: String
    public init(cursor: String, token: String) { self.cursor = cursor; self.token = token }
}

public struct LiveWait: Codable, Sendable, Equatable {
    public let token: String
    public let changed: Bool
    public let cursor: String?
    /// Set while the server shuts down: reconnect after this many seconds.
    public let retryAfter: Double?
    public init(token: String, changed: Bool, cursor: String? = nil, retryAfter: Double? = nil) {
        self.token = token; self.changed = changed; self.cursor = cursor; self.retryAfter = retryAfter
    }
}

public enum LiveRefreshError: Error, Equatable, Sendable {
    /// 429: too many waiters; `retryAfter` seconds (header `Retry-After`, default 5).
    case rateLimited(retryAfter: Double)
}

public protocol LiveRefreshTransport: Sendable {
    /// Capability block of `GET /v1/capabilities`; nil if the server does not offer live refresh.
    func liveCapability() async throws -> LiveRefreshCapability?
    /// `GET /v1/sync/head`; nil means 304 (token equals `ifNoneMatch`). 404 -> `APIError.notFound`.
    func liveHead(ifNoneMatch: String?) async throws -> LiveHead?
    /// `GET /v1/sync/wait` (long poll). 401 -> `APIError.unauthorized`, 404 -> `.notFound`, 429 -> `LiveRefreshError.rateLimited`.
    func liveWait(since: String?, timeout: Int) async throws -> LiveWait
}

public protocol LiveRefreshClock: Sendable {
    /// Monotonic seconds.
    func now() -> Double
    func sleep(seconds: Double) async throws
}

public struct SystemLiveRefreshClock: LiveRefreshClock {
    public init() {}
    public func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum LiveEvent: Sendable, Equatable {
    /// Something changed on the server (the sync action already ran). Refetch what is visible.
    case changed
    /// 401: the session is gone. The loop stopped; the app shows the signed-out state.
    case signedOut
    case modeChanged(LiveRefresh.Mode)
}

public actor LiveRefresh {
    public enum Mode: Sendable, Equatable {
        /// Not running (not started, in the background, or signed out).
        case idle
        /// `wait` long poll.
        case longPoll
        /// No `wait`: poll `head` every `pollSeconds`.
        case polling
        /// No `head` either: run the sync action every `pollSeconds`.
        case syncPolling
    }

    private let transport: any LiveRefreshTransport
    private let clock: any LiveRefreshClock
    private let syncAction: (@Sendable () async -> Void)?
    private let lowPower: @Sendable () -> Bool
    private let jitter: @Sendable () -> Double
    /// Minimum seconds between two `changed` notifications (bundling).
    private let minNotifyGap: Double

    public private(set) var mode: Mode = .idle
    private var started = false
    private var foreground = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<LiveEvent>.Continuation] = [:]

    // Loop state, kept across foreground/background so a return can detect what happened meanwhile.
    private var capability: LiveRefreshCapability?
    private var capabilityLoaded = false
    private var token: String?
    private var needsBaseline = true
    private var lastNotify: Double?
    private var activeMode: Mode = .longPoll

    public init(
        transport: any LiveRefreshTransport,
        clock: any LiveRefreshClock = SystemLiveRefreshClock(),
        minNotifyGap: Double = 1,
        lowPower: @escaping @Sendable () -> Bool = { false },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
        syncAction: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport; self.clock = clock; self.minNotifyGap = minNotifyGap
        self.lowPower = lowPower; self.jitter = jitter; self.syncAction = syncAction
    }

    /// Convenience: the sync action is `engine.sync()`.
    public init(client: APIClient, engine: SyncEngine?, lowPower: @escaping @Sendable () -> Bool = { false }) {
        var action: (@Sendable () async -> Void)?
        if let engine { action = { _ = try? await engine.sync() } }
        self.init(transport: client, lowPower: lowPower, syncAction: action)
    }

    // MARK: Subscribing

    public func events() -> AsyncStream<LiveEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func emit(_ event: LiveEvent) { for c in continuations.values { c.yield(event) } }

    // MARK: Lifecycle

    /// Account is signed in: the loop may run while the app is in the foreground.
    public func start() { started = true; reconcile() }
    /// Sign-out or account switch.
    public func stop() {
        started = false
        capability = nil; capabilityLoaded = false; token = nil; needsBaseline = true; lastNotify = nil
        reconcile()
    }
    /// scenePhase `.active` / app or window focus. On return the first `head` is compared with the last known token.
    public func setForeground(_ on: Bool) { foreground = on; reconcile() }

    public var isRunning: Bool { task != nil }

    private func reconcile() {
        let shouldRun = started && foreground
        if shouldRun, task == nil {
            generation += 1
            let gen = generation
            needsBaseline = true
            task = Task { [weak self] in await self?.run(gen) }
        } else if !shouldRun, let t = task {
            t.cancel(); task = nil; generation += 1
            setMode(.idle)
        }
    }

    private func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        emit(.modeChanged(m))
    }

    // MARK: Loop

    private func run(_ gen: Int) async {
        var failures = 0
        while !Task.isCancelled, gen == generation {
            do {
                // A head baseline alone proves little (the failing call may be `wait`), so only real progress resets.
                if try await step(gen) { failures = 0 }
            } catch is CancellationError {
                return
            } catch APIError.unauthorized(_) {
                guard gen == generation else { return }
                task = nil; generation += 1; started = false; setMode(.idle)
                emit(.signedOut)
                return
            } catch APIError.notFound {
                degrade()
            } catch LiveRefreshError.rateLimited(let after) {
                try? await clock.sleep(seconds: after)
            } catch {
                if Task.isCancelled || gen != generation { return }
                failures += 1
                needsBaseline = true  // changes may have been missed while the server was unreachable
                await backoff(failures)
            }
        }
    }

    private func degrade() {
        switch activeMode {
        case .longPoll: activeMode = .polling
        default: activeMode = .syncPolling
        }
        needsBaseline = true
        setMode(activeMode)
    }

    private var pollInterval: Double {
        Double(capability?.pollSeconds ?? 5) * (lowPower() ? 2 : 1)
    }

    @discardableResult
    private func step(_ gen: Int) async throws -> Bool {
        if !capabilityLoaded {
            capability = try await transport.liveCapability()
            capabilityLoaded = true
            if let c = capability {
                activeMode = !c.head ? .syncPolling : (c.wait ? .longPoll : .polling)
            } else {
                activeMode = .polling  // old server: head probably 404s and degrades to sync polling
            }
            setMode(activeMode)
        }
        switch activeMode {
        case .syncPolling:
            try await clock.sleep(seconds: pollInterval)
            try Task.checkCancellation()
            await notifyChanged(gen)
            return true
        case .polling:
            if needsBaseline { try await baseline(gen); return false }
            try await clock.sleep(seconds: pollInterval)
            try Task.checkCancellation()
            guard let head = try await transport.liveHead(ifNoneMatch: token), head.token != token else { return true }
            token = head.token
            await notifyChanged(gen)
        case .longPoll, .idle:
            if needsBaseline { try await baseline(gen); return false }
            let timeout = capability?.waitMaxSeconds ?? 25
            let r = try await transport.liveWait(since: token, timeout: timeout)
            try Task.checkCancellation()
            token = r.token
            if r.changed { await notifyChanged(gen) }
            if let after = r.retryAfter, after > 0 { try await clock.sleep(seconds: after) }
        }
        return true
    }

    /// Immediate `head`: first start only remembers the token, a return or recovery notifies if it moved meanwhile.
    private func baseline(_ gen: Int) async throws {
        let head = try await transport.liveHead(ifNoneMatch: nil)
        try Task.checkCancellation()
        guard gen == generation, let head else { return }
        let moved = token != nil && token != head.token
        token = head.token
        needsBaseline = false
        if moved { await notifyChanged(gen) }
    }

    private func notifyChanged(_ gen: Int) async {
        // Bundle: at most one notification per `minNotifyGap`; changes meanwhile are caught by the next wait/head.
        if let last = lastNotify {
            let rest = minNotifyGap - (clock.now() - last)
            if rest > 0 { try? await clock.sleep(seconds: rest) }
        }
        guard gen == generation, !Task.isCancelled else { return }
        await syncAction?()
        guard gen == generation, !Task.isCancelled else { return }
        lastNotify = clock.now()
        emit(.changed)
    }

    /// 1, 2, 4, 8, 16, 30 s with jitter. Beyond 5 s the server is probed with `head` every 5 s and the wait resumes
    /// as soon as it answers.
    private func backoff(_ failures: Int) async {
        let base = min(30.0, pow(2.0, Double(failures - 1)))
        var remaining = base * jitter()
        while remaining > 0, !Task.isCancelled {
            let chunk = min(5, remaining)
            do { try await clock.sleep(seconds: chunk) } catch { return }
            remaining -= chunk
            if remaining > 0, (try? await transport.liveHead(ifNoneMatch: nil)) != nil { return }
        }
    }
}

// MARK: APIClient transport

extension APIClient: LiveRefreshTransport {
    public func liveCapability() async throws -> LiveRefreshCapability? {
        try await capabilities().liveRefresh
    }

    public func liveHead(ifNoneMatch: String?) async throws -> LiveHead? {
        var headers: [String: String] = [:]
        if let t = ifNoneMatch { headers["If-None-Match"] = "\"\(t)\"" }
        let request = try makeRequest("GET", "v1/sync/head", query: [], body: nil, auth: true, headers: headers)
        let (data, http) = try await liveRaw(request)
        if http.statusCode == 304 { return nil }
        return try Self.liveDecode(LiveHead.self, data)
    }

    public func liveWait(since: String?, timeout: Int) async throws -> LiveWait {
        var query = [URLQueryItem(name: "timeout", value: String(timeout))]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        var request = try makeRequest("GET", "v1/sync/wait", query: query, body: nil, auth: true)
        request.timeoutInterval = Double(timeout) + 10
        let (data, _) = try await liveRaw(request)
        return try Self.liveDecode(LiveWait.self, data)
    }

    private func liveRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch { throw APIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300, 304: return (data, http)
        case 429:
            let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
            throw LiveRefreshError.rateLimited(retryAfter: max(1, after))
        default: throw APIError.from(status: http.statusCode, reason: nil)
        }
    }

    private static func liveDecode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
}
