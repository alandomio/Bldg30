import XCTest
@testable import ModelDeckCore

final class CompanionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func feed(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: Data(CompanionFixture.json(generatedAt: now).utf8)) as! [String: Any]
        edit(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }
    func testFixtureDecodes() throws {
        let value = try CompanionFeed.decode(try feed())
        XCTAssertEqual(value.decisions.count, 2); XCTAssertEqual(value.mrs.count, 2); XCTAssertEqual(value.tickets.count, 1)
        XCTAssertEqual(value.mrs[0].drafts[0].targetUrl, "https://example.com/svc/-/merge_requests/12")
        XCTAssertTrue(value.mrs[0].actions[1].outward)
        XCTAssertEqual(value.tickets[0].finish?.step, "Merge svc !12")
    }
    func testDocsFixtureDecodes() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/companion/fixture-feed.json")
        let value = try CompanionFeed.decode(try Data(contentsOf: path))
        XCTAssertEqual(value.decisions.map(\.id), ["dec-1", "dec-2"])
    }
    func testRejectsWrongSchemaUnknownVerdictAndInsecureUrl() throws {
        XCTAssertThrowsError(try CompanionFeed.decode(try feed { $0["schema"] = "companion-feed.v2" })) { XCTAssertEqual($0 as? CompanionError, .unsupportedSchema("companion-feed.v2")) }
        XCTAssertThrowsError(try CompanionFeed.decode(try feed { root in
            var mrs = root["mrs"] as! [[String: Any]]; mrs[0]["verdict"] = "maybe"; root["mrs"] = mrs }))
        XCTAssertThrowsError(try CompanionFeed.decode(try feed { root in
            var mrs = root["mrs"] as! [[String: Any]]; mrs[0]["url"] = "http://example.com/x"; root["mrs"] = mrs }))
        XCTAssertThrowsError(try CompanionFeed.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try CompanionFeed.decode(try feed { $0.removeValue(forKey: "generated_at") }))
    }
    func testRejectsDuplicateDecisionIDs() throws {
        XCTAssertThrowsError(try CompanionFeed.decode(try feed { root in
            var items = root["decisions"] as! [[String: Any]]; items[1]["id"] = items[0]["id"]; root["decisions"] = items }))
    }
    func testStaleness() throws {
        let value = try CompanionFeed.decode(try feed())
        XCTAssertFalse(value.isStale(now: now.addingTimeInterval(14 * 60)))
        XCTAssertTrue(value.isStale(now: now.addingTimeInterval(16 * 60)))
        XCTAssertEqual(value.age(now: now.addingTimeInterval(-10)), 0)
    }
    func testOnlyFreshUnannouncedUrgentDecisionsNotify() throws {
        let value = try CompanionFeed.decode(try feed())
        XCTAssertEqual(CompanionNotifications.pending(in: value, announced: [], now: now).map(\.id), ["dec-1"])
        XCTAssertEqual(CompanionNotifications.pending(in: value, announced: ["dec-1"], now: now), [])
        XCTAssertEqual(CompanionNotifications.pending(in: value, announced: [], now: now.addingTimeInterval(3600)), [])
    }
    func testBadgeShowsDecisionsOnlyWhenWaiting() {
        var options = MenuBarOptions(); options.metrics = [.cpu]; options.layout = .detailed
        func title(_ count: Int) -> String { MenuBarSummary.render(options: options, snapshot: .init(), claude: .init(provider: "Claude", source: "x"), openAI: .init(provider: "OpenAI", source: "x"), decisionsWaiting: count, now: now).title }
        XCTAssertFalse(title(0).contains("Decisioni"))
        XCTAssertTrue(title(3).hasSuffix("Decisioni 3"))
    }
    func testClickNoteIsWrittenAtomicallyWithExactDraftText() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let click = CompanionClick(actionID: "draft:d1", target: "https://example.com/x", draftText: "Exact \"text\"\nline two", now: now, key: "key-1")
        let note = try CompanionInbox.file(click, inbox: inbox.path, now: now)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as! [String: String]
        XCTAssertEqual(json["schema"], "companion-click.v1"); XCTAssertEqual(json["idempotency_key"], "key-1")
        XCTAssertEqual(json["action_id"], "draft:d1"); XCTAssertEqual(json["draft_text"], "Exact \"text\"\nline two")
        XCTAssertNotNil(json["created_at"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).count, 1)
        XCTAssertEqual(CompanionInbox.status(of: note), .sent)
        let handled = inbox.appendingPathComponent("handled"); try FileManager.default.createDirectory(at: handled, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: note, to: handled.appendingPathComponent(note.lastPathComponent))
        XCTAssertEqual(CompanionInbox.status(of: note), .pickedUp)
        try Data("{}".utf8).write(to: handled.appendingPathComponent(note.deletingPathExtension().lastPathComponent + ".reply.json"))
        XCTAssertEqual(CompanionInbox.status(of: note), .done)
    }
    func testClickNeedsAnExistingInbox() {
        let click = CompanionClick(actionID: "a", target: "t")
        XCTAssertThrowsError(try CompanionInbox.file(click, inbox: "")) { XCTAssertEqual($0 as? CompanionError, .noInbox) }
        XCTAssertThrowsError(try CompanionInbox.file(click, inbox: "/nonexistent-\(UUID().uuidString)")) { XCTAssertEqual($0 as? CompanionError, .unsafeInbox) }
    }
    func testEventFingerprintIsStableAndBatchingDedupes() throws {
        let a = CompanionEvent(kind: "new_comment", ref: "svc !12", source: "gitlab", state: "3 threads", now: now)
        let same = CompanionEvent(kind: "new_comment", ref: "svc !12", source: "gitlab", state: "3 threads", now: now.addingTimeInterval(60))
        let changed = CompanionEvent(kind: "new_comment", ref: "svc !12", source: "gitlab", state: "4 threads", now: now)
        XCTAssertEqual(a.fingerprint, same.fingerprint); XCTAssertNotEqual(a.fingerprint, changed.fingerprint)
        var batcher = CompanionEventBatcher()
        batcher.add(a); batcher.add(same); XCTAssertEqual(batcher.pendingCount, 1)
        let lines = try XCTUnwrap(batcher.flush(now: now))
        XCTAssertEqual(lines.split(separator: "\n").count, 1)
        XCTAssertTrue(lines.contains("\"schema\":\"companion-event.v1\""))
        batcher.add(same); XCTAssertEqual(batcher.pendingCount, 0, "already sent")
        batcher.add(changed)
        XCTAssertNil(batcher.flush(now: now.addingTimeInterval(299)), "one flush per 5 minutes")
        XCTAssertNotNil(batcher.flush(now: now.addingTimeInterval(300)))
    }
    func testDefenderSumsDaemonsByPrefixAndIsNilWhenAbsent() {
        func proc(_ pid: Int32, _ name: String, cpu: Double?, memory: UInt64) -> RunningProcess {
            RunningProcess(id: .init(pid: pid, startedSeconds: 1, startedMicroseconds: 0), name: name, path: nil, userID: 0, cpu: cpu, memory: memory, gpu: nil, gpuClient: false, threads: nil)
        }
        XCTAssertNil(DefenderUsage.summarize([proc(1, "Safari", cpu: 5, memory: 1)]))
        let usage = DefenderUsage.summarize([proc(1, "wdavdaemon", cpu: 2.5, memory: 10), proc(2, "wdavdaemon_enterprise", cpu: 4, memory: 20), proc(3, "wdavdaemon_unprivileged", cpu: nil, memory: 5), proc(4, "Safari", cpu: 50, memory: 99)])
        XCTAssertEqual(usage?.cpu, 6.5); XCTAssertEqual(usage?.memory, 35); XCTAssertEqual(usage?.processCount, 3)
        XCTAssertNil(DefenderUsage.summarize([proc(1, "wdavdaemon", cpu: nil, memory: 1)])?.cpu)
        var options = MenuBarOptions(); options.metrics = [.defender]; options.layout = .detailed
        func title(_ value: DefenderUsage?) -> String { MenuBarSummary.render(options: options, snapshot: .init(), claude: .init(provider: "Claude", source: "x"), openAI: .init(provider: "OpenAI", source: "x"), defender: value, now: now).title }
        XCTAssertEqual(title(nil), "Defender —")
        XCTAssertEqual(title(usage), "Defender " + DeckFormat.percent(6.5))
    }
    func testCommentClickCarriesTargetAndTextAndReplyIsReadByKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox"), replies = root.appendingPathComponent("replies")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let click = CompanionClick(actionID: CompanionReply.commentAction, target: "global", draftText: "ciao", now: now, key: "abcdef12")
        let note = try CompanionInbox.file(click, inbox: inbox.path, now: now)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as! [String: String]
        XCTAssertEqual(saved["action_id"], "comment_deck_officer"); XCTAssertEqual(saved["target"], "global"); XCTAssertEqual(saved["draft_text"], "ciao")
        XCTAssertNil(CompanionReply.read(key: "abcdef12", inbox: inbox.path))
        try Data(#"{"schema":"companion-reply.v1","idempotency_key":"abcdef12","note_id":"n","status":"done","text":"Fatto.","updated_at":"t"}"#.utf8).write(to: replies.appendingPathComponent("abcdef12.json"))
        XCTAssertEqual(CompanionReply.read(key: "abcdef12", inbox: inbox.path)?.text, "Fatto.")
        XCTAssertNil(CompanionReply.read(key: "../x", inbox: inbox.path))
    }
}
