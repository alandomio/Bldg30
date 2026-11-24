import XCTest
@testable import ModelDeckCore

final class FleetWorkersTests: XCTestCase {
    private let now = FleetWorkersTests.date("2026-11-13T16:00:00Z")
    private static func date(_ text: String) -> Date { CompanionFeed.date(text)! }

    private static func worker(_ id: String, _ state: String, at: String? = nil, extra: String = "") -> String {
        let stamp = at.map { "\"last_activity_at\":\"\($0)\"," } ?? ""
        return "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"project\":\"p\",\"kind\":\"ship\",\"harness\":\"claude\",\"model\":\"sonnet\",\"state\":\"\(state)\",\"crew_state\":\"x\",\"detail\":\"d\",\"waiting_on\":\"\",\(stamp)\"age_seconds\":100,\"links\":[]\(extra)}"
    }
    private static let states = FleetState.allCases.map(\.rawValue) + ["something new"]
    private lazy var fixture: Data = {
        let local = Self.states.enumerated().map { Self.worker("w\($0.offset)", $0.element, at: "2026-11-13T15:00:00Z") }.joined(separator: ",")
        let remote = "{\"id\":\"r1\",\"name\":\"r1\",\"project\":\"ts\",\"kind\":\"scout\",\"harness\":\"\",\"model\":\"\",\"state\":\"waiting on a decision\",\"crew_state\":\"blocked\",\"detail\":\"d\",\"waiting_on\":\"pick A or B\",\"last_activity_at\":null,\"age_seconds\":900,\"links\":[\"https://gitlab.com/g/p/-/merge_requests/7\",\"/tmp/report.md\"]}"
        return Data("""
        {"schema":"companion-workers.v1","generated_at":"2026-11-13T15:50:00Z","homes":[
         {"name":"main","machine":"mac","home":"/h","remote":false,"ok":true,"error":null,"observed_at":"2026-11-13T15:50:00Z","workers":[\(local)]},
         {"name":"alwayson","machine":"agent-host","home":"/r","remote":true,"ok":true,"error":null,"observed_at":"2026-11-13T15:49:00Z","summary_at":"2026-11-13T15:48:00Z","omitted":0,"workers":[\(remote)]},
         {"name":"watson","machine":"mac","home":"/w","remote":false,"ok":false,"error":"ssh: timeout","observed_at":"2026-11-13T15:50:00Z","workers":[]}
        ]}
        """.utf8)
    }()

    func testDecodesHomesAndEveryState() throws {
        let snapshot = try FleetSnapshot.decode(fixture)
        XCTAssertEqual(snapshot.homes.map(\.name), ["main", "alwayson", "watson"])
        let main = snapshot.homes[0].workers
        XCTAssertEqual(main.count, FleetState.allCases.count + 1)
        for (index, state) in FleetState.allCases.enumerated() { XCTAssertEqual(main[index].state, state) }
        XCTAssertEqual(main.last?.state, .unknown, "an unknown state string decodes as unknown")
        XCTAssertEqual(snapshot.homes[1].workers[0].engine, "—")
        XCTAssertNil(snapshot.homes[1].workers[0].lastActivityAt)
        XCTAssertEqual(snapshot.homes[1].workers[0].waitingOn, "pick A or B")
        XCTAssertEqual(snapshot.homes[1].summaryAt, Self.date("2026-11-13T15:48:00Z"))
    }

    func testUnreachableHomeKeepsItsError() throws {
        let home = try FleetSnapshot.decode(fixture).homes[2]
        XCTAssertFalse(home.ok); XCTAssertEqual(home.error, "ssh: timeout"); XCTAssertTrue(home.workers.isEmpty)
    }

    func testMissingFieldsNeverCrashAndHomeWithoutOkIsNotTrusted() throws {
        let data = Data("{\"schema\":\"companion-workers.v1\",\"generated_at\":\"2026-11-13T15:50:00Z\",\"homes\":[{\"name\":\"h\",\"workers\":[{\"id\":\"a\"},{\"name\":\"b\",\"state\":5}]}]}".utf8)
        let home = try FleetSnapshot.decode(data).homes[0]
        XCTAssertFalse(home.ok)
        XCTAssertEqual(home.workers.map(\.id), ["a", "b"]); XCTAssertEqual(home.workers.map(\.state), [.unknown, .unknown])
    }

    func testRejectsWrongSchemaAndBadTopLevel() {
        XCTAssertThrowsError(try FleetSnapshot.decode(Data("{\"schema\":\"v2\",\"generated_at\":\"2026-11-13T15:50:00Z\",\"homes\":[]}".utf8))) { XCTAssertEqual($0 as? CompanionError, .unsupportedSchema("v2")) }
        XCTAssertThrowsError(try FleetSnapshot.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try FleetSnapshot.decode(Data("{\"schema\":\"companion-workers.v1\",\"homes\":[]}".utf8)))
        XCTAssertThrowsError(try FleetSnapshot.read(path: "/nonexistent/workers.json")) { XCTAssertEqual($0 as? CompanionError, .missingFile) }
    }

    func testInvalidAgesAreUnknownInTheDisplayConversion() throws {
        // This is the conversion used by both FleetView age labels, not just a decoder check.
        for value in [1e100, Double(Int.max), -1, Double.infinity, -.infinity, .nan] {
            XCTAssertNil(FleetAge.minutes(value), "invalid display age: \(value)")
        }
        XCTAssertNil(FleetAge.minutes(nil))
        XCTAssertEqual(FleetAge.minutes(0), 0)
        XCTAssertEqual(FleetAge.minutes(119), 1)
        XCTAssertEqual(FleetAge.minutes(7200), 120)
        XCTAssertNotNil(FleetAge.minutes(Double(Int.max).nextDown))

        for value in ["1e100", "-1", String(Double(Int.max))] {
            let worker = try JSONDecoder().decode(FleetWorker.self, from: Data("""
            {"id":"bad-age","state":"done","age_seconds":\(value)}
            """.utf8))
            XCTAssertNil(worker.ageSeconds)
            XCTAssertNil(worker.age(now: now))
            XCTAssertNil(FleetAge.minutes(worker.age(now: now)))
            XCTAssertEqual(FleetSnapshot.rows([worker], showFinished: false, now: now).count, 1)
        }
        let timestamped = try JSONDecoder().decode(FleetWorker.self, from: Data("""
        {"id":"timestamped","last_activity_at":"2026-11-13T15:00:00Z","age_seconds":1e100}
        """.utf8))
        XCTAssertEqual(FleetAge.minutes(timestamped.age(now: now)), 60)
        XCTAssertNil(FleetAge.minutes(timestamped.age(now: Date(timeIntervalSince1970: 1e100))))
    }

    func testMalformedEntryNextToValidWorkerRejectsSnapshot() throws {
        for invalid in ["null", "42", "[]", "\"bad\""] {
            let data = Data("""
            {"schema":"companion-workers.v1","generated_at":"2026-11-13T15:50:00Z",
             "homes":[{"name":"healthy","ok":true,"workers":[{"id":"good","state":"working"},\(invalid)]}]}
            """.utf8)
            XCTAssertThrowsError(try FleetSnapshot.decode(data)) { error in
                guard case .invalid = error as? CompanionError else { return XCTFail("expected snapshot error: \(error)") }
            }
        }
        for invalid in ["null", "42", "{}"] {
            let data = Data("""
            {"schema":"companion-workers.v1","generated_at":"2026-11-13T15:50:00Z",
             "homes":[{"ok":true,"workers":\(invalid)}]}
            """.utf8)
            XCTAssertThrowsError(try FleetSnapshot.decode(data))
        }
    }

    func testUnnamedRowsUseStableSourcePositionsWithoutNamedIDCollisions() throws {
        let data = Data("""
        {"workers":[{}, {}, {"kind":"decision"}, {"id":"index:0"}, {"name":"named"}]}
        """.utf8)
        let home = try JSONDecoder().decode(FleetHome.self, from: data)
        XCTAssertEqual(home.workers.map(\.rowID), ["worker/index:0", "worker/index:1", "decision/index:2",
                                                  "worker/id:index:0", "worker/id:named"])
        XCTAssertEqual(Set(home.workers.map(\.rowID)).count, 5)
        XCTAssertEqual(try JSONDecoder().decode(FleetHome.self, from: data).workers.map(\.rowID), home.workers.map(\.rowID))
    }

    func testProducerWorkerAndDecisionHaveSeparateRowAndExpansionIdentities() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("wire/tests/fleet_overlap.py").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let home = try XCTUnwrap(FleetSnapshot.decode(data).homes.first)
        XCTAssertEqual(home.workers.map(\.id), ["held-worker", "held-worker"])
        XCTAssertEqual(home.workers.map(\.rowID), ["worker/id:held-worker", "decision/id:held-worker"])
        let rows = FleetSnapshot.rows(home.workers, showFinished: false, now: now)
        XCTAssertEqual(Set(rows.map(\.rowID)).count, 2)
        let expansionKeys = rows.map { home.id + "/" + $0.rowID }
        XCTAssertEqual(Set(expansionKeys).count, 2)
        let expanded = Set([expansionKeys[0]])
        XCTAssertFalse(expanded.contains(expansionKeys[1]))
        let reload = try XCTUnwrap(FleetSnapshot.decode(data).homes.first)
        XCTAssertEqual(reload.workers.map(\.rowID), home.workers.map(\.rowID))
    }

    func testStaleAfterThirtyMinutes() throws {
        let snapshot = try FleetSnapshot.decode(fixture)   // generated 15:50
        XCTAssertFalse(snapshot.isStale(now: Self.date("2026-11-13T16:19:00Z")))
        XCTAssertTrue(snapshot.isStale(now: Self.date("2026-11-13T16:21:00Z")))
        XCTAssertEqual(snapshot.age(now: now), 600)
    }

    func testMachinesGroupHomesInOrder() throws {
        let groups = try FleetSnapshot.decode(fixture).machines
        XCTAssertEqual(groups.map(\.machine), ["mac", "agent-host"])
        XCTAssertEqual(groups[0].homes.map(\.name), ["main", "watson"])
    }

    func testCountsByState() throws {
        let counts = try FleetSnapshot.decode(fixture).homes[0].counts
        XCTAssertEqual(counts.first { $0.state == .unknown }?.count, 2)
        XCTAssertEqual(counts.first { $0.state == .working }?.count, 1)
    }

    func testSortAndFinishedFilter() throws {
        func w(_ id: String, _ state: String, _ at: String?) throws -> FleetWorker {
            let json = Self.worker(id, state, at: at)
            return try JSONDecoder().decode(FleetWorker.self, from: Data(json.utf8))
        }
        let list = [try w("work-new", "working", "2026-11-13T15:55:00Z"), try w("work-old", "working", "2026-11-13T10:00:00Z"),
                    try w("idle", "idle", "2026-11-12T10:00:00Z"), try w("dead", "dead", "2026-11-13T15:00:00Z"),
                    try w("paused", "paused", "2026-11-13T12:00:00Z"), try w("prompt", "waiting on a prompt", "2026-11-13T15:50:00Z"),
                    try w("decision", "waiting on a decision", "2026-11-13T14:00:00Z"), try w("blocked", "blocked", "2026-11-13T15:00:00Z"),
                    try w("fresh-done", "done", "2026-11-13T09:00:00Z"), try w("old-done", "done", "2026-11-11T09:00:00Z"),
                    try w("old-stopped", "stopped", "2026-11-10T09:00:00Z")]
        XCTAssertEqual(FleetSnapshot.rows(list, showFinished: false, now: now).map(\.id),
                       ["decision", "blocked", "prompt", "work-old", "work-new", "paused", "idle", "fresh-done", "dead"])
        XCTAssertEqual(FleetSnapshot.rows(list, showFinished: true, now: now).count, list.count)
    }

    func testLinks() {
        XCTAssertEqual(FleetLink.make("https://gitlab.com/g/p/-/merge_requests/407"), .web(URL(string: "https://gitlab.com/g/p/-/merge_requests/407")!, label: "MR !407"))
        XCTAssertEqual(FleetLink.make("/Users/a/report.md"), .file(URL(fileURLWithPath: "/Users/a/report.md"), label: "report.md"))
        XCTAssertNil(FleetLink.make("http://insecure.example/x"))
        XCTAssertNil(FleetLink.make("javascript:alert(1)"))
    }
}
