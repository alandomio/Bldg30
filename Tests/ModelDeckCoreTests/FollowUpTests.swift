import Testing
import Foundation
@testable import ModelDeckCore

// Swift Testing so these also run with the Command Line Tools, which lack XCTest.
@Suite struct FollowUpTests {
    // argv-index-crash
    @Test func aFlagWithoutAValueReadsAsAbsent() {
        #expect(CommandArguments.value(after: "--feed", in: ["app", "--feed"]) == nil)
        #expect(CommandArguments.value(after: "--feed", in: ["app", "--feed", "/tmp/f.json"]) == "/tmp/f.json")
        #expect(CommandArguments.value(after: "--inbox", in: ["app", "--feed", "/tmp/f.json"]) == nil)
        #expect(CommandArguments.value(after: "--feed", in: ["app", "--feed", "--inbox", "/x"]) == nil)
    }

    // queued-line-before-inbox-check
    @Test func noInboxFolderMeansNoQueuedLineAndAnError() throws {
        let click = CompanionClick(actionID: "a.opt-1", target: "a")
        for inbox in ["", "   "] {
            let stray = CommandLog.url(inbox: inbox)
            let before = try FileManager.default.fileExists(atPath: stray.path) ? Data(contentsOf: stray) : nil
            let error = ClickSender.send(click, label: "Go", inbox: inbox)
            let after = try FileManager.default.fileExists(atPath: stray.path) ? Data(contentsOf: stray) : nil
            #expect(error == CompanionError.noInbox.errorDescription)
            #expect(after == before, "commands.jsonl changed without an inbox")
        }
    }
    @Test func aWorkingInboxQueuesThenFilesAndABrokenOneQueuesThenFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox"); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let click = CompanionClick(actionID: "a.opt-1", target: "a", key: "k1")
        #expect(ClickSender.send(click, label: "Go", inbox: inbox.path) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).count == 1)
        #expect(CommandLedger(lines: CommandLog.read(CommandLog.url(inbox: inbox.path))).command(id: "k1")?.state == .queued)
        let broken = CompanionClick(actionID: "a.opt-2", target: "a", key: "k2")
        let missing = root.appendingPathComponent("gone").path
        #expect(ClickSender.send(broken, label: nil, inbox: missing) != nil)
        // The failed line lands in the log beside the missing folder, so the card shows Failed instead of Sent.
        #expect(CommandLedger(lines: CommandLog.read(CommandLog.url(inbox: missing))).command(id: "k2")?.state == .failed)
    }

    // drop-hidden-after-failed-send
    @Test func aDropComesBackWhenItsSendFails() {
        var drops = DropQueue()
        drops.begin("d1")
        #expect(drops.isHidden("d1"))
        let expired = drops.expire("d1")
        #expect(expired)
        #expect(drops.isHidden("d1"))
        drops.sendFailed("d1")
        #expect(!drops.isHidden("d1"))
        drops.begin("d2"); drops.undo("d2")
        let late = drops.expire("d2")
        #expect(!drops.isHidden("d2") && !late)
    }

    // sweep-repeatable-while-queued
    @Test func workerActionsWaitForTheCommandInFlight() {
        func line(_ id: String, _ state: String, _ action: String) -> String {
            #"{"id":"\#(id)","action_id":"\#(action)","target":"worker:a","state":"\#(state)","at":"2026-11-03T08:00:00Z"}"#
        }
        let queued = CommandLedger(lines: [line("c1", "queued", WorkerActions.sweep)])
        for action in [WorkerActions.sweep, WorkerActions.cleanup, WorkerActions.discard] {
            #expect(!WorkerActions.mayRun(action, task: "a", ledger: queued))
        }
        #expect(WorkerActions.mayRun(WorkerActions.steer, task: "a", ledger: queued))
        #expect(WorkerActions.mayRun(WorkerActions.sweep, task: "b", ledger: queued))
        let failed = CommandLedger(lines: [line("c1", "queued", WorkerActions.sweep), line("c1", "failed", WorkerActions.sweep)])
        #expect(WorkerActions.mayRun(WorkerActions.sweep, task: "a", ledger: failed))
        #expect(WorkerActions.mayRun(WorkerActions.sweep, task: "a", ledger: CommandLedger(lines: [])))
    }
}
