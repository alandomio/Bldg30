import Testing
import Foundation
@testable import ModelDeckCore

// Swift Testing so these also run with the Command Line Tools, which lack XCTest.
@Suite struct BridgeTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func gitlabNode(_ iid: Int, status: String? = "SUCCESS", resolvable: Int = 2, resolved: Int = 1) -> String {
        let pipeline = status.map { #"{"status":"\#($0)"}"# } ?? "null"
        return #"{"iid":"\#(iid)","title":"MR \#(iid)","webUrl":"https://example.com/svc/-/merge_requests/\#(iid)","updatedAt":"2027-01-15T08:00:00Z","reference":"grp/svc!\#(iid)","project":{"fullPath":"grp/svc"},"headPipeline":\#(pipeline),"resolvableDiscussionsCount":\#(resolvable),"resolvedDiscussionsCount":\#(resolved)}"#
    }
    func gitlab(authored: [String], reviewing: [String]) -> Data {
        Data(#"{"data":{"currentUser":{"authored":{"nodes":[\#(authored.joined(separator: ","))]},"reviewing":{"nodes":[\#(reviewing.joined(separator: ","))]}}}}"#.utf8)
    }
    func mr(_ iid: Int, role: String = "author", pipeline: String = "passed", threads: Int = 1, updated: TimeInterval = 0) -> RawMR {
        RawMR(ref: "grp/svc!\(iid)", title: "MR \(iid)", role: role, pipeline: pipeline, projectPath: "grp/svc", iid: iid, openThreads: threads,
              url: URL(string: "https://example.com/svc/-/merge_requests/\(iid)")!, updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + updated))
    }
    func ticket(_ id: String, state: String = "In Review", updated: TimeInterval = 0) -> BoardTicket {
        BoardTicket(id: id, identifier: id, title: "T \(id)", state: state, url: URL(string: "https://example.com/issue/\(id)")!, updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + updated))
    }
    func feed() throws -> CompanionFeed { try CompanionFeed.decode(Data(CompanionFixture.json(generatedAt: t0).utf8)) }

    @Test func parsesAuthoredAndReviewingWithUnresolvedThreads() throws {
        let list = try GitLabBoard.parse(gitlab(authored: [gitlabNode(1, status: "FAILED", resolvable: 3, resolved: 1)], reviewing: [gitlabNode(2, status: nil), gitlabNode(1)]))
        #expect(list.map(\.ref) == ["grp/svc!1", "grp/svc!2"])
        #expect(list[0].role == "author" && list[0].pipeline == "failed" && list[0].openThreads == 2)
        #expect(list[1].role == "reviewer" && list[1].pipeline == "none" && list[1].iid == 2)
    }
    @Test func malformedOrErrorResponsesThrowInsteadOfReadingAsEmpty() {
        #expect(throws: (any Error).self) { try GitLabBoard.parse(gitlab(authored: [#"{"iid":"1"}"#], reviewing: [])) }
        #expect(throws: (any Error).self) { try GitLabBoard.parse(Data(#"{"data":{"currentUser":null}}"#.utf8)) }
        #expect(throws: (any Error).self) { try GitLabBoard.parse(Data(#"{"errors":[{"message":"401"}]}"#.utf8)) }
    }
    @Test func queryUsesUsernameVariableOnlyWhenSet() {
        #expect(GitLabBoard.query(username: nil).contains("currentUser"))
        #expect(GitLabBoard.query(username: "adomio").contains("user(username: $u)"))
    }
    @Test func hostMustBeHttpsOrLocalhost() throws {
        #expect(try GitLabBoard.endpoint(host: "gitlab.example.com").absoluteString == "https://gitlab.example.com")
        #expect(try GitLabBoard.endpoint(host: "http://localhost:8080").host == "localhost")
        for bad in ["http://gitlab.example.com", "https://user@gitlab.example.com", "https://gitlab.example.com/x", ""] {
            #expect(throws: (any Error).self) { try GitLabBoard.endpoint(host: bad) }
        }
    }
    @Test func newerRawStateOverridesFeedAndMarksVerdictStale() throws {
        let raw = RawBoard(tickets: [ticket("IN-1", state: "Done"), ticket("IN-9")], mrs: [mr(12, pipeline: "passed", threads: 0), mr(40, role: "reviewer")],
                           linearOK: true, gitlabOK: true, fetchedAt: t0.addingTimeInterval(600))
        let mrs = CompanionBoard.mrs(feed: try feed(), raw: raw)
        let first = mrs.first { $0.ref == "svc !12" }!
        #expect(first.pipeline == "passed" && first.openThreads == 0 && first.verdictStale && first.verdict == "notyet")
        let unchanged = mrs.first { $0.ref == "tool !7" }!
        #expect(unchanged.verdictStale)  // tool !7 is no longer open on GitLab
        let added = mrs.first { $0.ref == "grp/svc!40" }!
        #expect(added.verdict == nil && added.actions.isEmpty)
        let tickets = CompanionBoard.tickets(feed: try feed(), raw: raw)
        #expect(tickets.first { $0.identifier == "IN-1" }!.status == "Done" && tickets.first { $0.identifier == "IN-1" }!.finishStale)
        #expect(tickets.map(\.identifier) == ["IN-1", "IN-9"])
    }
    @Test func olderOrFailedRawDataNeverTouchesTheFeed() throws {
        let older = RawBoard(tickets: [ticket("IN-1", state: "Done")], mrs: [mr(12, pipeline: "failed", threads: 9)], linearOK: true, gitlabOK: true, fetchedAt: t0.addingTimeInterval(-60))
        #expect(CompanionBoard.mrs(feed: try feed(), raw: older).first { $0.ref == "svc !12" }!.openThreads == 2)
        let failed = RawBoard(tickets: [], mrs: [], linearOK: false, gitlabOK: false, fetchedAt: t0.addingTimeInterval(600))
        #expect(CompanionBoard.mrs(feed: try feed(), raw: failed).allSatisfy { !$0.verdictStale })
        #expect(CompanionBoard.tickets(feed: try feed(), raw: failed).allSatisfy { !$0.finishStale })
    }
    @Test func eventsCoverPipelineThreadsReviewTicketAndVanishedAndFirstPollIsSilent() {
        let old = RawBoard(tickets: [ticket("IN-1")], mrs: [mr(1, pipeline: "running", threads: 0), mr(3)], linearOK: true, gitlabOK: true)
        let new = RawBoard(tickets: [ticket("IN-1", state: "Done")], mrs: [mr(1, pipeline: "passed", threads: 2), mr(2, role: "reviewer")], linearOK: true, gitlabOK: true)
        #expect(CompanionDiff.events(old: nil, new: new).events.isEmpty)
        let change = CompanionDiff.events(old: old, new: new, now: t0)
        #expect(Set(change.events.map(\.kind)) == ["pipeline_changed", "new_comment", "review_requested", "ticket_state"])
        #expect(change.vanished.map(\.iid) == [3])
        #expect(CompanionDiff.events(old: new, new: new).events.isEmpty)
        var failed = new; failed.gitlabOK = false; failed.mrs = []
        #expect(CompanionDiff.events(old: old, new: failed).vanished.isEmpty)
    }
    @Test func eventsReachTheBatcherOnceAndLandInTheFile() throws {
        var batcher = CompanionEventBatcher()
        let event = CompanionEvent(kind: "ticket_state", ref: "IN-1", source: "linear", state: "Done", now: t0)
        batcher.add(event); batcher.add(event)
        let flushed = batcher.flush(now: t0)
        let lines = try #require(flushed)
        #expect(lines.split(separator: "\n").count == 1)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString)/e.jsonl").path
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try CompanionEventFile.append(lines, to: path); try CompanionEventFile.append(lines, to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count == 2)
        #expect(lines.contains("\"schema\":\"companion-event.v1\""))
    }
    @Test func dossierFileNamesAreSafe() {
        #expect(Dossier.fileName(for: "svc !12") == "svc-12.json")
        #expect(Dossier.fileName(for: "IN-1") == "IN-1.json")
        #expect(Dossier.fileName(for: "../../etc/passwd") == "etc-passwd.json")
    }
    @Test func dossierLookupHandlesMissingLoadedAndInvalid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let feedPath = root.appendingPathComponent("feed.json").path
        #expect(Dossier.lookup(ref: "IN-1", feedPath: feedPath) == .missing)
        let folder = root.appendingPathComponent("dossiers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"summary":"S","timeline":[{"at":"2027-01-15","text":"opened"}],"open_decisions":["D"],"gotchas":["G"],"links":[{"label":"Report","url":"https://example.com/r"}],"next_action":"Merge","generated_at":"2027-01-15T08:00:00Z"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("IN-1.json"))
        guard case .loaded(let dossier) = Dossier.lookup(ref: "IN-1", feedPath: feedPath) else { Issue.record("not loaded"); return }
        #expect(dossier.summary == "S" && dossier.nextAction == "Merge" && dossier.openDecisions == ["D"] && dossier.timeline[0].text == "opened" && dossier.links.count == 1)
        try Data(#"{"summary":"only"}"#.utf8).write(to: folder.appendingPathComponent("IN-2.json"))
        guard case .invalid = Dossier.lookup(ref: "IN-2", feedPath: feedPath) else { Issue.record("expected invalid"); return }
        try Data(json.replacingOccurrences(of: "https://example.com/r", with: "http://example.com/r").utf8).write(to: folder.appendingPathComponent("IN-3.json"))
        guard case .invalid = Dossier.lookup(ref: "IN-3", feedPath: feedPath) else { Issue.record("expected invalid link"); return }
    }
    @Test func addContextClickCarriesTheTypedText() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let note = try CompanionInbox.file(CompanionClick(actionID: "add_context", target: "IN-1", draftText: "Waiting on infra", now: t0, key: "k"), inbox: inbox.path, now: t0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as? [String: String])
        #expect(json["schema"] == "companion-click.v1" && json["action_id"] == "add_context" && json["draft_text"] == "Waiting on infra" && json["target"] == "IN-1")
    }
}
