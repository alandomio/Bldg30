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

    @Test func nullPipelineAndThreadsDecodeAndOneBadRowIsSkippedWithAWarning() throws {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(CompanionFixture.json(generatedAt: t0).utf8)) as? [String: Any])
        var mrs = try #require(root["mrs"] as? [[String: Any]])
        mrs[0]["pipeline"] = NSNull(); mrs[0]["open_threads"] = NSNull()
        var broken = mrs[1]; broken["ref"] = "bad !1"; broken["role"] = "owner"; mrs.append(broken)
        var typo = mrs[1]; typo["ref"] = "bad !2"; typo["open_threads"] = "two"; mrs.append(typo)
        root["mrs"] = mrs; root["warnings"] = ["producer note"]
        let value = try CompanionFeed.decode(try JSONSerialization.data(withJSONObject: root))
        #expect(value.mrs.map(\.ref) == ["svc !12", "tool !7"])
        #expect(value.mrs[0].pipeline == nil && value.mrs[0].openThreads == nil)
        #expect(value.skipped.count == 2 && Set(value.skipped.map { String($0.prefix(6)) }) == ["mrs[2]", "mrs[3]"])
        #expect(value.warnings == ["producer note"])
        let row = CompanionBoard.mrs(feed: value, raw: nil)[0]
        #expect(row.pipeline == nil && row.openThreads == nil)
    }
    @Test func realFeedDecodesWhenPresent() throws {
        let path = NSString(string: CompanionFeed.defaultPath).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let value = try CompanionFeed.decode(data)
        #expect(!value.mrs.isEmpty && value.skipped.isEmpty)
        print("REALFEED", value.decisions.count, value.mrs.count, value.tickets.count, "skipped", value.skipped)
    }

    func defenderProcess(_ pid: Int32, _ path: String, cpu: Double? = nil, memory: UInt64? = nil) -> RunningProcess {
        RunningProcess(id: .init(pid: pid, startedSeconds: 1, startedMicroseconds: 0), name: URL(fileURLWithPath: path).lastPathComponent, path: path, userID: 0, cpu: cpu, memory: memory, gpu: nil, gpuClient: false, threads: nil)
    }
    @Test func defenderIsFoundByRealRootProcessNamesAndPaths() {
        let real = [
            defenderProcess(832, "/Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon"),
            defenderProcess(841, "/Library/SystemExtensions/BA9FCDDB-16BD-4750-B555-3025B1E297D2/com.microsoft.wdav.epsext.systemextension/Contents/MacOS/epsext"),
            defenderProcess(940, "/Library/SystemExtensions/9911C98A-84A9-474D-9524-0B5AA598C3E9/com.microsoft.wdav.netext.systemextension/Contents/MacOS/netext"),
            defenderProcess(1011, "/Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon_enterprise.app/Contents/MacOS/wdavdaemon_enterprise"),
            defenderProcess(72858, "/Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon_unprivileged.app/Contents/MacOS/wdavdaemon_unprivileged"),
            defenderProcess(5, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 9, memory: 9),
            defenderProcess(6, "/Library/SystemExtensions/ABC/com.example.other.systemextension/Contents/MacOS/epsext", cpu: 9, memory: 9)]
        let hidden = DefenderUsage.summarize(real)
        #expect(hidden?.processCount == 5 && hidden?.usageAvailable == false && hidden?.cpu == nil && hidden?.memory == 0)
        var readable = real; readable[1] = defenderProcess(841, real[1].path!, cpu: 100, memory: 50); readable[0] = defenderProcess(832, real[0].path!, cpu: 1.5, memory: 10)
        let usage = DefenderUsage.summarize(readable)
        #expect(usage?.usageAvailable == true && usage?.cpu == 101.5 && usage?.memory == 60)
        #expect(DefenderUsage.summarize([defenderProcess(5, "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 1, memory: 1)]) == nil)
    }
    @Test func theProcessListIncludesRootProcessesOnlyWhenAsked() async {
        let plain = await ProcessMonitor().sample(), wide = await ProcessMonitor(includeUnreadable: true).sample()
        #expect(wide.count >= plain.count)
        #expect(wide.contains { $0.pid == 1 && $0.cpu == nil })  // launchd is root: hidden from task info, visible through sysctl
        #expect(!plain.contains { $0.pid == 1 })
    }

    // Real `agy -p "/usage" --output-format json` output from 2026-11-02 (no account data in it).
    static let agySample = #"{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-09T06:42:06Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-09T06:42:06Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.755,"reset_time":"2026-11-09T06:42:06Z"}]}]}}}"#
    @Test func parsesAntigravityUsageIntoQuotaWindows() throws {
        let usage = try GeminiUsage.parse(Data(Self.agySample.utf8), now: t0)
        #expect(usage.provider == "Google" && usage.message == nil && usage.windows.count == 2)
        #expect(usage.windows[0].id == "gemini-weekly" && usage.windows[0].usedPercent == 0 && usage.windows[0].durationMinutes == 10080)
        #expect(usage.windows[0].title == "Modelli Gemini · 7 giorni" && usage.windows[1].title == "Modelli Claude e GPT · 7 giorni")
        #expect(abs(usage.windows[1].usedPercent - 24.5) < 0.001)
        #expect(usage.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-09T06:42:06Z"))
    }
    @Test func antigravityErrorsAndOddShapesThrowInsteadOfReadingAsZeroUsage() {
        for bad in [#"{"status":"ERROR"}"#, #"{"status":"SUCCESS","command":{"data":{}}}"#, #"{"status":"SUCCESS","command":{"data":{"groups":[{"name":"G","buckets":[{"id":"x","remaining_fraction":2}]}]}}}"#, "not json"] {
            #expect(throws: (any Error).self) { try GeminiUsage.parse(Data(bad.utf8)) }
        }
    }
}
