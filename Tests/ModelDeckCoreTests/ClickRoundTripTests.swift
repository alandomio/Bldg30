import Foundation
import Testing
@testable import ModelDeckCore

/// Click round trip (test B), end to end: for every button of every sample feed, the app's own code builds the click and
/// sends it (ClickSender: a `queued` line in commands.jsonl, then the note in a temporary inbox). The real click pipe
/// (wire/tests/click_roundtrip.py runs wire.clicks with a stub firstmate inbox) must match it to the right work item,
/// acknowledge it and answer it, writing its states into the same commands.jsonl, and the app's ledger must read it as done.
struct ClickRoundTripTests {
    static let wire = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("wire")
    static let feeds = wire.appendingPathComponent("fixtures/feeds")
    static let now = Date(timeIntervalSince1970: 1_795_000_000)

    struct Report: Decodable {
        struct Click: Decodable { let filed: Bool, stale: Bool, note: String, handled: Bool }
        let runs: [Int]
        let errors: String
        let clicks: [String: Click]
    }

    /// Every button a card offers, built the way CompanionView builds it.
    static func buttons(of feed: CompanionFeed) -> [CompanionClick] {
        var out: [CompanionClick] = []
        func key() -> String { String(format: "click%04d-swift", out.count) }
        func add(_ click: CompanionClick?) { if let click { out.append(click) } }
        for decision in feed.decisions {
            for (index, option) in decision.options.enumerated() {
                add(CompanionAnswer.click(decisionID: decision.id, option: option, optionIndex: index, text: "", now: now, key: key()))
            }
            add(CompanionAnswer.click(decisionID: decision.id, text: "Free answer text", now: now, key: key()))
            add(CompanionAnswer.contextClick(ref: decision.id, text: "Context for the decision", now: now, key: key()))
        }
        for mr in feed.mrs {
            for draft in mr.drafts {
                if let id = ReviewDrafts.actionID(for: draft, in: mr.actions) {
                    add(CompanionClick(actionID: id, target: mr.ref, draftText: draft.text, now: now, key: key()))
                }
            }
            for action in ReviewDrafts.buttons(mr.actions) { add(CompanionClick(actionID: action.id, target: mr.ref, now: now, key: key())) }
            add(CompanionAnswer.contextClick(ref: mr.ref, text: "Context for the MR", now: now, key: key()))
        }
        for ticket in feed.tickets {
            for action in ticket.actions { add(CompanionClick(actionID: action.id, target: ticket.identifier, now: now, key: key())) }
            add(CompanionAnswer.contextClick(ref: ticket.identifier, text: "Context for the ticket", now: now, key: key()))
        }
        return out
    }

    static func runPipe(inbox: URL, commands: URL, sample: String) throws -> Report {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", wire.appendingPathComponent("tests/click_roundtrip.py").path, "--inbox", inbox.path,
                             "--feed", feeds.appendingPathComponent("\(sample).feed.json").path,
                             "--actions", feeds.appendingPathComponent("\(sample).feed.actions.json").path,
                             "--commands", commands.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try JSONDecoder().decode(Report.self, from: data)
    }

    @Test(arguments: ["producer", "edge-cases"])
    func everyButtonReachesItsWorkItemAndIsAnswered(sample: String) throws {
        let feed = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("\(sample).feed.json")))
        let clicks = Self.buttons(of: feed)
        #expect(clicks.count > feed.decisions.count + feed.mrs.count + feed.tickets.count)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for click in clicks { #expect(ClickSender.send(click, label: nil, inbox: inbox.path) == nil, "\(click.actionID) was not sent") }
        let commands = CommandLog.url(inbox: inbox.path)
        #expect(CommandLedger(lines: CommandLog.read(commands)).commands.allSatisfy { $0.state == .queued })

        let report = try Self.runPipe(inbox: inbox, commands: commands, sample: sample)
        #expect(report.runs == [0, 0, 0])
        #expect(report.errors == "")
        let ledger = CommandLedger(lines: CommandLog.read(commands))
        for click in clicks {
            let name = report.clicks.keys.first { $0.hasSuffix("-\(click.idempotencyKey).json") }
            let result = try #require(name.flatMap { report.clicks[$0] }, "no result for \(click.actionID)")
            #expect(result.filed, "\(click.actionID) never reached firstmate")
            #expect(!result.stale, "\(click.actionID) is a dead button: the pipe cannot map it")
            #expect(result.note.contains("Action id: \(click.actionID)"))
            if let text = click.draftText { #expect(result.note.contains(text)) }
            #expect(result.handled)
            let command = try #require(ledger.command(id: click.idempotencyKey), "\(click.actionID) is missing from the ledger")
            #expect(command.state == .done, "\(click.actionID) must read as done in the app")
            #expect(command.target == click.target)
        }
    }

    @Test func buttonsUseTheFeedsClickIDs() throws {
        let feed = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("producer.feed.json")))
        let decision = try #require(feed.decisions.first)
        let option = try #require(CompanionAnswer.click(decisionID: decision.id, option: decision.options[0], optionIndex: 0, text: ""))
        #expect(option.actionID == "row-mr-obs-42.opt-approve-now")
        let mr = try #require(feed.mrs.first { $0.ref == "obs !42" })
        #expect(ReviewDrafts.actionID(for: mr.drafts[0], in: mr.actions) == nil, "no comment action for this draft: no dead button")
        let edge = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("edge-cases.feed.json")))
        let reviewed = try #require(edge.mrs.first { $0.ref == "obs !9" })
        #expect(ReviewDrafts.actionID(for: reviewed.drafts[0], in: reviewed.actions) == "row-mr-obs-9.comment-f1")
    }
}
