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
