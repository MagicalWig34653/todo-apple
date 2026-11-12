import XCTest
@testable import TodoCore

final class SystemStatusTests: XCTestCase {
    private let json = #"{"items":[{"source":"default","label":"Mac","reportedAt":"2026-11-12T10:00:00Z","status":{"claude_ampel":"gelb","claude_nutzbare_konten":[4,7,"x"],"claude_frei_fuer_brain":3,"codex":{"verbraucht_pct":5,"erlaubt_bis_jetzt_pct":19.2,"ziel_pct":80,"freigabe":true},"platte_ampel":"gruen","platte_frei_gb":104.9,"zukunft":{"a":1}}}],"now":"2026-11-12T10:12:30Z"}"#

    private func decode(_ s: String) throws -> SystemStatusResponse {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SystemStatusResponse.self, from: Data(s.utf8))
    }

    func testDecodesKnownFieldsAndIgnoresUnknown() throws {
        let r = try decode(json)
        let s = try XCTUnwrap(r.items.first).status
        XCTAssertEqual(s.claudeAmpel, .gelb)
        XCTAssertEqual(s.claudeAccounts, [4, 7])
        XCTAssertEqual(s.codex?.usedPct, 5)
        XCTAssertEqual(s.codex?.allowedPct, 19.2)
        XCTAssertEqual(s.codex?.isWarning, false)
        XCTAssertEqual(s.diskAmpel, .gruen)
        XCTAssertEqual(s.diskFreeGB, 104.9)
    }

    func testMalformedFieldsDropOut() throws {
        let r = try decode(#"{"items":[{"source":"a","reportedAt":"2026-11-12T10:00:00Z","status":{"claude_ampel":"blau","codex":{"verbraucht_pct":"viel"},"platte_frei_gb":"x"}}],"now":"2026-11-12T10:00:00Z"}"#)
        XCTAssertTrue(r.items[0].status.isEmpty)
        XCTAssertTrue(try decode(#"{"items":[],"now":"2026-11-12T10:00:00Z"}"#).items.isEmpty)
    }

    func testCodexWarning() throws {
        XCTAssertTrue(CodexStatus(usedPct: 30, allowedPct: 19, targetPct: nil, release: nil).isWarning)
        XCTAssertTrue(CodexStatus(usedPct: 5, allowedPct: 19, targetPct: nil, release: false).isWarning)
        XCTAssertFalse(CodexStatus(usedPct: 5, allowedPct: nil, targetPct: nil, release: nil).isWarning)
    }

    func testAgeAndStale() throws {
        let r = try decode(json)
        let item = r.items[0]
        let fetched = Date()
        XCTAssertEqual(item.ageMinutes(serverNow: r.now, fetchedAt: fetched, now: fetched), 12)
        // Local time since the answer arrived is added; a clock going backwards never makes it negative.
        XCTAssertEqual(item.ageMinutes(serverNow: r.now, fetchedAt: fetched, now: fetched.addingTimeInterval(20 * 60)), 32)
        XCTAssertEqual(item.ageMinutes(serverNow: item.reportedAt.addingTimeInterval(-600), fetchedAt: fetched, now: fetched), 0)
        XCTAssertFalse(SystemStatusItem.isStale(ageMinutes: 30))
        XCTAssertTrue(SystemStatusItem.isStale(ageMinutes: 31))
    }
}
