import Foundation
import CryptoKit

public struct VoiceWorkerSettings: Sendable {
    /// Capability report to the server (it treats a device as reachable for 90 s).
    public var capabilityInterval: Duration = .seconds(30)
    /// Lease extension; the server lease is 60 s.
    public var leaseInterval: Duration = .seconds(30)
    /// Wait between claim attempts when there is nothing to do.
    public var pollInterval: Duration = .seconds(5)
    /// Scratch directory for incoming and generated audio. Emptied at start; per-job folders are removed after every job.
    public var workDirectory: URL
    public var now: @Sendable () -> Date = { Date() }
    /// Log lines contain job ids and codes only, never audio, transcripts or reply texts.
    public var log: @Sendable (String) -> Void = { _ in }
    public init(workDirectory: URL) { self.workDirectory = workDirectory }
}

public enum VoiceJobOutcome: Equatable, Sendable {
    /// Result accepted by the server.
    case done
    /// The runner reported an error result (job is failed on the server).
    case reportedFailure(String)
    /// 409/410/404 or local lease expiry: nothing was or will be published for this claim.
    case leaseLost
    /// Server or network error before a result could be delivered; the lease runs out and the job can be claimed again.
    case undelivered
}

/// Processes voice jobs of the Brain channel (ADR 0030): claim, lease heartbeat, download, local STT, reply text, local TTS, upload.
/// Audio only goes to the user's server (the `VoiceServer`); engines are local. Every file lives in a per-job folder that is
/// removed after success, failure and lease loss.
public actor VoiceWorker {
    private let server: any VoiceServer
    private let stt: any SpeechToText
    private let tts: any TextToSpeech
    private let responder: any ResponseProvider
    private let settings: VoiceWorkerSettings
    private var processing = false

    public init(server: any VoiceServer, stt: any SpeechToText, tts: any TextToSpeech,
                responder: any ResponseProvider = AcknowledgementResponseProvider(), settings: VoiceWorkerSettings) {
        self.server = server; self.stt = stt; self.tts = tts; self.responder = responder; self.settings = settings
    }

    /// "sprache" only when the speech model AND the German voice are available.
    public nonisolated func capabilities() -> [String] { stt.isReady && tts.isReady ? ["sprache"] : [] }

    /// Reports capabilities once. Returns the effective ones, nil if the server was not reachable.
    @discardableResult
    public func reportCapabilities() async -> [String]? {
        do { return try await server.heartbeat(capabilities: capabilities()) }
        catch { settings.log("Sprach-Heartbeat fehlgeschlagen: \(Self.describe(error))"); return nil }
    }

    /// Removes leftovers of an earlier crash.
    public func sweepWorkDirectory() {
        let root = settings.workDirectory
        for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Reports capabilities periodically and works jobs until cancelled.
    public func runLoop() async {
        sweepWorkDirectory()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                while !Task.isCancelled {
                    await reportCapabilities()
                    try? await Task.sleep(for: settings.capabilityInterval)
                }
            }
            group.addTask { [self] in
                while !Task.isCancelled {
                    if await pollOnce() == nil { try? await Task.sleep(for: settings.pollInterval) }
                }
            }
        }
    }

    /// Claims and works at most one job. Returns nil if nothing was claimed (no capability, nothing queued, server unreachable).
    @discardableResult
    public func pollOnce() async -> VoiceJobOutcome? {
        guard !processing, !capabilities().isEmpty else { return nil }
        let job: VoiceJob?
        do { job = try await server.claimNext() }
        catch RunnerServerError.conflict, RunnerServerError.gone {
            return nil  // another runner (or a running job of this account) won
        } catch {
            settings.log("Sprachauftrag holen fehlgeschlagen: \(Self.describe(error))")
            return nil
        }
        guard let job else { return nil }
        processing = true
        defer { processing = false }
        settings.log("Sprachauftrag \(job.id.uuidString.prefix(8).lowercased()) übernommen (Generation \(job.generation))")
        let outcome = await process(job)
        settings.log("Sprachauftrag \(job.id.uuidString.prefix(8).lowercased()) beendet: \(outcome)")
        return outcome
    }

    // MARK: Job

    private func process(_ job: VoiceJob) async -> VoiceJobOutcome {
        let directory = settings.workDirectory.appendingPathComponent(job.id.uuidString.lowercased() + "-\(job.generation)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return .undelivered }
        let leaseDeadline = job.leaseUntil ?? settings.now().addingTimeInterval(60)

        return await withTaskGroup(of: VoiceJobOutcome?.self) { group in
            group.addTask { [self] in await work(job, in: directory) }
            group.addTask { [self] in await keepLease(job, deadline: leaseDeadline) }
            var outcome: VoiceJobOutcome = .undelivered
            while let next = await group.next() {
                if let next { outcome = next; group.cancelAll(); break }
            }
            // The cancelled sibling must finish before the folder goes away (it may still hold a file open).
            for await _ in group {}
            return outcome
        }
    }

    /// Returns `.leaseLost` once the server fences us (or the local lease ran out); nil when cancelled.
    private func keepLease(_ job: VoiceJob, deadline initial: Date) async -> VoiceJobOutcome? {
        var deadline = initial
        while !Task.isCancelled {
            try? await Task.sleep(for: settings.leaseInterval)
            if Task.isCancelled { return nil }
            do {
                let renewed = try await server.heartbeat(jobID: job.id, generation: job.generation)
                if let until = renewed.leaseUntil { deadline = until }
            } catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound {
                return .leaseLost
            } catch {
                if settings.now() >= deadline { return .leaseLost }
            }
        }
        return nil
    }

    private func work(_ job: VoiceJob, in directory: URL) async -> VoiceJobOutcome? {
        func fail(_ code: String) async -> VoiceJobOutcome? {
            if Task.isCancelled { return nil }
            do {
                try await server.result(jobID: job.id, generation: job.generation, transcript: nil, replyText: nil, errorCode: code)
                return .reportedFailure(code)
            } catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound { return .leaseLost }
            catch { return .undelivered }
        }

        // 1. Recording (the checksum from the claim is verified again here).
        guard let info = job.audio else { return await fail("audio_missing") }
        let audio: Data
        do { audio = try await server.downloadAudio(jobID: job.id, generation: job.generation) }
        catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound { return .leaseLost }
        catch { return .undelivered }
        guard audio.count == info.size, Self.sha256(audio) == info.checksum.lowercased() else { return await fail("audio_corrupt") }
        let input = directory.appendingPathComponent(info.mediaType == "audio/wav" ? "in.wav" : "in.m4a")
        do { try audio.write(to: input, options: [.atomic, .completeFileProtection]) } catch { return await fail("audio_unwritable") }
        if Task.isCancelled { return nil }

        // 2. Local transcription.
        let transcript: String
        do { transcript = String(try await stt.transcribe(audioFile: input).prefix(VoiceLimits.maxTextCharacters)) }
        catch { settings.log("Transkription fehlgeschlagen (\(type(of: error)))"); return await fail("transcription_failed") }
        try? FileManager.default.removeItem(at: input)  // the recording is no longer needed locally
        if Task.isCancelled { return nil }

        // 3. Reply text.
        let reply: String
        do { reply = String(try await responder.reply(toTranscript: transcript).prefix(VoiceLimits.maxTextCharacters)) }
        catch { settings.log("Antworttext fehlgeschlagen (\(type(of: error)))"); return await fail("reply_failed") }
        if Task.isCancelled { return nil }

        // 4. Reply audio; without it the text-only reply is still delivered.
        let replyFile = directory.appendingPathComponent("reply.m4a")
        var uploaded = false
        do {
            try await tts.synthesize(reply, to: replyFile)
            let data = try Data(contentsOf: replyFile)
            if data.count > VoiceLimits.maxBytes { throw VoiceEngineError.replyTooLong }
            if Task.isCancelled { return nil }
            try await server.uploadReplyAudio(jobID: job.id, generation: job.generation, audio: data, mediaType: "audio/mp4")
            uploaded = true
        } catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound {
            return .leaseLost
        } catch {
            settings.log("Antwortaudio nicht geliefert (\(type(of: error))), nur Text")
        }
        _ = uploaded
        if Task.isCancelled { return nil }

        // 5. Result.
        do {
            try await server.result(jobID: job.id, generation: job.generation, transcript: transcript, replyText: reply, errorCode: nil)
            return .done
        } catch let error as RunnerServerError where error.isOwnershipLoss || error == .notFound {
            return .leaseLost
        } catch {
            settings.log("Ergebnis nicht zugestellt: \(Self.describe(error))")
            return .undelivered
        }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func describe(_ error: Error) -> String {
        if let error = error as? RunnerServerError { return String(describing: error) }
        return String(describing: type(of: error))
    }
}
