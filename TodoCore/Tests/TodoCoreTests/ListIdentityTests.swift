import XCTest
@testable import TodoCore

/// Card 21A79A08: SwiftUI mixes rows up when two entries of a `ForEach` share an id. Every list below is fed by data that can
/// repeat its natural key.
final class ListIdentityTests: XCTestCase {
    private let p1 = "11111111-1111-1111-1111-111111111111"
    private let t1 = "22222222-2222-2222-2222-222222222222"
    private let a1 = "aaaaaaaa-0000-0000-0000-000000000001"
    private let a2 = "aaaaaaaa-0000-0000-0000-000000000002"

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Two screenshots of one build, registered in the same second: only the server's `id` (1.5.0) tells them apart.
    private func shots(_ ids: [String?]) throws -> [OverviewBuild] {
        let builds = ids.map { id in
            #"{\#(id.map { #""id":"\#($0)","# } ?? "")"taskID":"\#(t1)","buildID":"b7","label":"Login","createdAt":"2026-11-18T11:00:00Z"}"#
        }
        let json = #"{"projects":[{"projectID":"\#(p1)","projectName":"A","builds":[\#(builds.joined(separator: ","))]}]}"#
        return try decoder().decode(OverviewNow.self, from: Data(json.utf8)).projects[0].builds
    }

    func testTwoScreenshotsOfOneBuildUseTheServerID() throws {
        let builds = try shots([a1, a2])
        XCTAssertEqual(builds.map(\.id), [a1, a2].map { UUID(uuidString: $0)!.uuidString })
        XCTAssertEqual(builds.map(\.buildID), ["b7", "b7"])
    }

    func testTwoScreenshotsOfOneBuildFromAnOldServerStayDistinct() throws {
        let builds = try shots([nil, nil])
        XCTAssertEqual(builds.count, 2)
        XCTAssertEqual(Set(builds.map(\.id)).count, 2, "ids: \(builds.map(\.id))")
        // Stable across a refresh, and the first rows keep their id when the list grows.
        XCTAssertEqual(try shots([nil, nil]).map(\.id), builds.map(\.id))
        XCTAssertEqual(Array(try shots([nil, nil, nil]).map(\.id).prefix(2)), builds.map(\.id))
    }

    /// The server keys a session by person, project and name: two people of a shared project may use the same name.
    func testSessionsWithOneNameStayDistinct() throws {
        let session = #"{"sessionName":"main","activity":"x","updatedAt":"2026-11-18T11:00:00Z"}"#
        let row = #"{"kind":"session","projectID":"\#(p1)","projectName":"A","title":"main"}"#
        let json = #"{"projects":[{"projectID":"\#(p1)","projectName":"A","sessions":[\#(session),\#(session)]}],"now":{"running":[\#(row),\#(row)],"silent":[\#(row),\#(row)]}}"#
        let overview = try decoder().decode(OverviewNow.self, from: Data(json.utf8))
        XCTAssertEqual(Set(overview.projects[0].sessions.map(\.id)).count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(overview.now).running.map(\.id)).count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(overview.now).silent.map(\.id)).count, 2)
    }

    /// Question options, answer buttons and reminders: the server accepts repeated values.
    func testRepeatedValuesGetDistinctKeys() {
        XCTAssertEqual(uniqueKeys(["Ja", "Nein"]), ["Ja", "Nein"])
        XCTAssertEqual(uniqueKeys(["Ja", "Ja", "Ja#2", "Ja"]), ["Ja", "Ja#2", "Ja#2#2", "Ja#3"])
        let reminder = Date(timeIntervalSince1970: 1_800_000_000)
        let keyed = [reminder, reminder].uniquelyKeyed { "\($0.timeIntervalSince1970)" }
        XCTAssertEqual(Set(keyed.map(\.id)).count, 2)
        XCTAssertEqual(keyed.map(\.item), [reminder, reminder])
    }

    /// "Mehr laden" tapped twice sends the same cursor twice: the page must not appear a second time.
    func testActivityPageAppendedTwiceStaysOnce() throws {
        func item(_ id: String) throws -> ActivityItem {
            let json = #"{"source":"task","id":"\#(id)","projectID":"\#(p1)","projectName":"A","sequence":1,"actorType":"Person","actorID":"\#(t1)","kind":"task.created"}"#
            return try decoder().decode(ActivityItem.self, from: Data(json.utf8))
        }
        let first = try [item(a1)], second = try [item(a2)]
        XCTAssertEqual(first.appendingPage(second).appendingPage(second).map(\.id), (first + second).map(\.id))
    }
}
