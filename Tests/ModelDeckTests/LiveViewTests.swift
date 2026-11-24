import Foundation
import Testing
@testable import ModelDeck
@testable import ModelDeckCore

@Suite @MainActor struct LiveViewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let config = LiveConfiguration(home: "/fixtures/other-home", feedPath: "/fixtures/other-output/feed.json")
    private static let ok = ExecResult(status: 0, output: "", error: "", timedOut: false)

    private func live(at: Date) throws -> CompanionLive {
        try CompanionLive.decode(JSONSerialization.data(withJSONObject: [
            "schema": CompanionLive.schema, "generated_at": ISO8601DateFormatter().string(from: at), "events": []
        ]))
    }
    private func feed(at: Date) throws -> CompanionFeed {
        try CompanionFeed.decode(Data(CompanionFixture.json(generatedAt: at).utf8))
    }
    private func drop(_ id: String, state: CommandState) throws -> CommandLedger {
        let states: [CommandState] = state == .queued ? [.queued] : [.queued, state]
        let lines = try states.map {
            String(decoding: try JSONEncoder().encode(CommandRecord(id: "click", actionID: id + ".opt-drop",
                target: id, state: $0, at: now)), as: UTF8.self)
        }
        let ledger = CommandLedger(lines: lines)
        #expect(ledger.ignoredLines == 0)
        #expect(ledger.commands.first?.state == state)
        return ledger
    }

    @Test func refreshUsesSelectedHomeAndFeedDirectoryWithPortableScript() async throws {
        let stale = try live(at: now - 60)
        for script in [nil, "/fixtures/custom/wire.py"] as [String?] {
            let selected = LiveConfiguration(home: config.home, feedPath: config.feedPath, scriptPath: script)
            var paths: [String] = []
            var calls = 0
            let model = LiveModel(configuration: { selected }, read: { path in paths.append(path); return stale },
                run: { executable, arguments, environment, timeout in
                    calls += 1
                    #expect(executable == "/usr/bin/python3")
                    #expect(arguments == [script ?? "/fixtures/other-home/data/shipdeck-wire/bin/wire.py", "live"])
                    #expect(environment == ["FM_HOME": "/fixtures/other-home", "SHIPDECK_COMPANION": "/fixtures/other-output"])
                    #expect(timeout == 10)
                    return Self.ok
                }, now: { now })
            await model.tick()
            #expect(calls == 1)
            #expect(paths == ["/fixtures/other-output/live.json", "/fixtures/other-output/live.json"])
        }
    }

    @Test func pinnedDecisionsAndCountUseTheDropLedger() throws {
        let source = try feed(at: now)
        let id = try #require(source.decisions.first?.id)
        for state in [CommandState.queued, .done] {
            let content = LivePageContent(feed: source, ledger: try drop(id, state: state), error: nil, now: now)
            #expect(content.decisions.map(\.id) == source.decisions.dropFirst().map(\.id))
            #expect(content.decisions.count == source.decisions.count - 1)
        }
        let failed = LivePageContent(feed: source, ledger: try drop(id, state: .failed), error: nil, now: now)
        #expect(failed.decisions == source.decisions)
    }

    @Test func closeAndReopenDuringRefreshKeepsOneProducerAndTheRunGap() async throws {
        let probe = RefreshProbe(value: try live(at: now - 60))
        var clock = now
        let model = LiveModel(configuration: { config }, read: probe.read,
            run: { _, _, _, _ in await probe.run() }, now: { clock })
        model.start()
        await probe.waitForStart()
        #expect(model.running)
        model.stop()
        model.start()
        await probe.waitForReads(2)
        #expect(model.running)
        #expect(probe.calls == 1)
        model.stop()
        probe.finish()
        await model.tick()
        #expect(!model.running)
        #expect(probe.calls == 1)
        clock += 14
        await model.tick()
        #expect(probe.calls == 1)
        clock += 1
        await model.tick()
        #expect(probe.calls == 2)
    }

    @Test func decisionFeedAgeAndReadErrorRemainSeparateFromFreshStatusEvents() async throws {
        let fresh = try live(at: now)
        let model = LiveModel(configuration: { config }, read: { _ in fresh },
            run: { _, _, _, _ in Issue.record("Fresh status file must not run the producer"); return Self.ok }, now: { now })
        await model.tick()
        #expect(model.live?.generatedAt == now)
        #expect(model.error == nil)
        let oldFeed = try feed(at: now - CompanionFeed.outdatedAfter - 1)
        let content = LivePageContent(feed: oldFeed, ledger: CommandLedger(), error: "feed read failed", now: now)
        #expect(content.decisionAge == 1801)
        #expect(content.decisionOutdated)
        #expect(content.decisionError == "feed read failed")
        #expect(content.decisions == oldFeed.decisions)
        let boundary = LivePageContent(feed: try feed(at: now - 1800), ledger: CommandLedger(), error: nil, now: now)
        #expect(!boundary.decisionOutdated)
        let missing = LivePageContent(feed: nil, ledger: CommandLedger(), error: "missing feed", now: now)
        #expect(missing.decisionAge == nil)
        #expect(missing.decisionError == "missing feed")
    }
}

@MainActor private final class RefreshProbe {
    let value: CompanionLive
    var calls = 0
    private var reads = 0
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<ExecResult, Never>?
    private var readWaiter: (Int, CheckedContinuation<Void, Never>)?
    init(value: CompanionLive) { self.value = value }
    func read(_ path: String) -> CompanionLive {
        reads += 1
        if let (count, waiter) = readWaiter, reads >= count { readWaiter = nil; waiter.resume() }
        return value
    }
    func run() async -> ExecResult {
        calls += 1
        if calls > 1 { return ExecResult(status: 0, output: "", error: "", timedOut: false) }
        return await withCheckedContinuation {
            completion = $0
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func waitForReads(_ count: Int) async {
        if reads >= count { return }
        await withCheckedContinuation { readWaiter = (count, $0) }
    }
    func finish() {
        completion?.resume(returning: ExecResult(status: 0, output: "", error: "", timedOut: false))
        completion = nil
    }
}
