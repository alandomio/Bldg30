import Foundation
import Testing
@testable import ModelDeckCore

struct ClickRoundTripTests {
    static let wire = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("wire")
    static let feeds = wire.appendingPathComponent("fixtures/feeds")
    static let now = Date(timeIntervalSince1970: 1_795_000_000)

    struct Report: Decodable {
        struct Click: Decodable {
            let filed: Bool, stale: Bool, note: String, handled: Bool
            let noteHomes: [String]

            enum CodingKeys: String, CodingKey {
                case filed, stale, note, handled
                case noteHomes = "note_homes"
            }
        }
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

    static func workerButtons() throws -> [CompanionClick] {
        let worker = Worker(meta: WorkerMeta(id: "finished-worker"), crew: nil,
                            events: StatusLog.parse("done: Verdict: all green"), now: now)
        let sweep = try #require(WorkerActions.sweepClick(worker, now: now))
        let steer = try #require(WorkerActions.steerClick(task: "running-worker", text: "Check the failing test", now: now))
        let target = WorkerActions.target(worker.id)
        return [sweep, steer] + [WorkerActions.cleanup, WorkerActions.discard, "worker.merge"].map {
            CompanionClick(actionID: $0, target: target, now: now)
        }
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

    @Test(arguments: ["producer", "edge-cases", "shipdeck-skill"])
    func everyButtonReachesItsWorkItemAndIsAnswered(sample: String) throws {
        let feed = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("\(sample).feed.json")))
        let cardClicks = Self.buttons(of: feed)
        #expect(cardClicks.count > feed.decisions.count + feed.mrs.count + feed.tickets.count)
        let clicks = try cardClicks + Self.workerButtons()
        let commentTargets = ["global"] + feed.decisions.map(\.id) + feed.mrs.map(\.ref) + feed.tickets.map(\.identifier)
        let comments = commentTargets.map {
            CompanionClick(actionID: CompanionReply.commentAction, target: $0, draftText: "Please check \($0)", now: Self.now)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for click in clicks { #expect(ClickSender.send(click, label: nil, inbox: inbox.path) == nil, "\(click.actionID) was not sent") }
        for comment in comments { try CompanionInbox.file(comment, inbox: inbox.path) }
        let commands = CommandLog.url(inbox: inbox.path)
        let queued = CommandLedger(lines: CommandLog.read(commands)).commands
        #expect(Set(queued.map(\.id)) == Set(clicks.map(\.idempotencyKey)))
        #expect(queued.allSatisfy { $0.state == .queued })

        let report = try Self.runPipe(inbox: inbox, commands: commands, sample: sample)
        #expect(report.runs == [0, 0, 0])
        #expect(report.errors == "")
        let ledger = CommandLedger(lines: CommandLog.read(commands))
        for click in clicks + comments {
            let name = report.clicks.keys.first { $0.hasSuffix("-\(click.idempotencyKey).json") }
            let result = try #require(name.flatMap { report.clicks[$0] }, "no result for \(click.actionID)")
            #expect(result.filed, "\(click.actionID) never reached firstmate")
            #expect(!result.stale, "\(click.actionID) is a dead button: the pipe cannot map it")
            #expect(result.note.contains("Target: \(click.target)\n"))
            if let text = click.draftText { #expect(result.note.contains(text)) }
            #expect(result.handled)
            if click.actionID == CompanionReply.commentAction {
                #expect(result.noteHomes == ["deck_officer"])
                let reply = try #require(CompanionReply.read(key: click.idempotencyKey, inbox: inbox.path))
                #expect(reply.status == "done")
                #expect(reply.text == "done: deck_officer \(click.idempotencyKey)")
                continue
            }
            #expect(result.noteHomes == ["main"])
            #expect(result.note.contains("Action id: \(click.actionID)\n"))
            let command = try #require(ledger.command(id: click.idempotencyKey), "\(click.actionID) is missing from the ledger")
            #expect(command.state == .done, "\(click.actionID) must read as done in the app")
            #expect(command.actionID == click.actionID)
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

    @Test func heldSkillOptionsUseTheirLabelsAndKeepTypedContext() throws {
        let feed = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("shipdeck-skill.feed.json")))
        let decision = try #require(feed.decisions.first)
        let options = decision.options.filter { !$0.isStandard }
        #expect(options.map(\.label) == ["Discard the copy (close the worker)", "Keep it"])
        #expect(options[0].consequence == "the unpushed commit is dropped; nothing is lost, its content is already on main.")
        #expect(decision.recommendation == "discard the copy, since main already has every file.")
        #expect(CompanionRecommendation.optionIndex(recommendation: decision.recommendation, options: options) == 0)
        for (index, option) in options.enumerated() {
            let click = try #require(CompanionAnswer.click(decisionID: decision.id, option: option, optionIndex: index, text: ""))
            #expect(click.actionID == "shipdeck-skill.opt-\(index + 1)")
            #expect(click.target == "shipdeck-skill" && click.draftText == nil && click.selectedOption?.label == option.label)
            let context = try #require(CompanionAnswer.click(decisionID: decision.id, option: option, optionIndex: index, text: "After review.\n"))
            #expect(context.actionID == click.actionID && context.draftText == "After review.")
        }
    }
}
