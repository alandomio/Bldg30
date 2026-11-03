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
        #expect(Dossier.fileName(for: "IN-1") == "in-1.json" && Dossier.fileName(for: "aim !307") == "aim-307.json")
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
        try Data(json.utf8).write(to: folder.appendingPathComponent("in-1.json"))
        guard case .loaded(let dossier) = Dossier.lookup(ref: "IN-1", feedPath: feedPath) else { Issue.record("not loaded"); return }
        #expect(dossier.summary == "S" && dossier.nextAction == "Merge" && dossier.openDecisions == ["D"] && dossier.timeline[0].text == "opened" && dossier.links.count == 1)
        try Data(#"{"summary":"only"}"#.utf8).write(to: folder.appendingPathComponent("in-2.json"))
        guard case .invalid = Dossier.lookup(ref: "IN-2", feedPath: feedPath) else { Issue.record("expected invalid"); return }
        let objects = json.replacingOccurrences(of: #""open_decisions":["D"]"#, with: #""open_decisions":[{"id":"x","title":"Post the review","recommendation":"option 1","links":["https://example.com"]},"Plain"],"gotchas":[{"text":"Careful"}]"#)
        try Data(objects.utf8).write(to: folder.appendingPathComponent("in-4.json"))
        guard case .loaded(let withObjects) = Dossier.lookup(ref: "IN-4", feedPath: feedPath) else { Issue.record("objects not loaded"); return }
        #expect(withObjects.openDecisions == ["Post the review", "Plain"] && withObjects.gotchas == ["Careful"])
        let mixed = json.replacingOccurrences(of: #"[{"label":"Report","url":"https://example.com/r"}]"#, with: #"[{"label":"Local","url":"file:///Users/x/report.md"},{"label":"Plain","url":"http://example.com/r"},{"label":"Loop","url":"http://127.0.0.1:4387/s/1"},{"label":"Bad"}]"#)
        try Data(mixed.utf8).write(to: folder.appendingPathComponent("in-3.json"))
        guard case .loaded(let withLinks) = Dossier.lookup(ref: "IN-3", feedPath: feedPath) else { Issue.record("expected loaded"); return }
        #expect(withLinks.links.map(\.label) == ["Local", "Loop"])
    }
    @Test func addContextClickCarriesTheTypedText() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        #expect(CompanionAnswer.contextClick(ref: "IN-1", text: "  \n") == nil)
        let note = try CompanionInbox.file(try #require(CompanionAnswer.contextClick(ref: "IN-1", text: "Waiting on infra \n", now: t0, key: "k")), inbox: inbox.path, now: t0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as? [String: String])
        #expect(json["schema"] == "companion-click.v1" && json["action_id"] == "IN-1.add-context" && json["draft_text"] == "Waiting on infra" && json["target"] == "IN-1")
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
        var partial = real; partial[4] = defenderProcess(72858, real[4].path!, cpu: 0.1, memory: 5)  // the one process of the user is readable
        #expect(DefenderUsage.summarize(partial)?.usageAvailable == false)
        let readable = real.prefix(5).enumerated().map { defenderProcess($0.element.pid, $0.element.path!, cpu: $0.offset == 1 ? 100 : 0.5, memory: 10) }
        let usage = DefenderUsage.summarize(readable)
        #expect(usage?.usageAvailable == true && usage?.cpu == 102 && usage?.memory == 50)
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

    @Test func decisionAnswerClicksHaveTheRightShape() throws {
        let fixture = try feed().decisions[0]
        let free = try #require(CompanionAnswer.click(decisionID: "dec-1", text: "  Ship it\n  but keep the flag \n\n", now: t0, key: "k1"))
        #expect(free.actionID == "dec-1.answer" && free.target == "dec-1" && free.draftText == "  Ship it\n  but keep the flag")
        let option = fixture.options[1]
        let both = try #require(CompanionAnswer.click(decisionID: "dec-1", option: option, optionIndex: 1, text: "Only after Friday", now: t0, key: "k2"))
        #expect(both.actionID == "dec-1.opt-2" && both.draftText == "Only after Friday")  // the feed's own id, not a made-up one
        let bareOption = CompanionFeed.Option(label: "Old", consequence: "c", actionId: nil, outward: nil, standard: nil)
        #expect(CompanionAnswer.click(decisionID: "dec-1", option: bareOption, optionIndex: 3, text: "")?.actionID == "decision:dec-1:option:3")  // only for feeds without ids
        let bare = try #require(CompanionAnswer.click(decisionID: "dec-1", option: option, optionIndex: 1, text: "  ", now: t0, key: "k3"))
        #expect(bare.draftText == option.label)
        let custom = CompanionFeed.Option(label: "Go", consequence: "c", actionId: "act-9", outward: nil, standard: nil)
        #expect(CompanionAnswer.click(decisionID: "d", option: custom, text: "x")?.actionID == "act-9")
        #expect(CompanionAnswer.click(decisionID: "dec-1", text: " \n ") == nil)
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let note = try CompanionInbox.file(free, inbox: inbox.path, now: t0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: note)) as? [String: String])
        #expect(json["schema"] == "companion-click.v1" && json["action_id"] == "dec-1.answer" && json["target"] == "dec-1" && json["draft_text"] == "  Ship it\n  but keep the flag" && json["idempotency_key"] == "k1")
        #expect(Set(json.keys) == ["schema", "idempotency_key", "action_id", "target", "draft_text", "created_at"])
        #expect(CompanionInbox.status(of: note) == .sent)
    }

    @Test func realDossiersDecodeWhenPresent() throws {
        let feedPath = NSString(string: CompanionFeed.defaultPath).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: feedPath) else { return }
        let value = try CompanionFeed.decode(data)
        let refs = value.mrs.map(\.ref) + value.tickets.map(\.identifier)
        var loaded = 0
        for ref in refs { switch Dossier.lookup(ref: ref, feedPath: feedPath) { case .loaded: loaded += 1; case .invalid(let why): Issue.record("\(ref): \(why)"); case .missing: break } }
        print("REALDOSSIERS", loaded, "of", refs.count)
    }

    @Test func optionalMrContextFieldsDecodeAndEmptyOnesCountAsAbsent() throws {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(CompanionFixture.json(generatedAt: t0).utf8)) as? [String: Any])
        var mrs = try #require(root["mrs"] as? [[String: Any]])
        mrs[0].merge(["author": "alandomio", "headline": "Waiting on review", "blocker": "Two threads open", "next": "Reply to Klemens", "ticket": "IN-2566", "updated_at": "2027-01-15T08:00:00Z"]) { $1 }
        mrs[1].merge(["author": "", "headline": "", "blocker": "", "next": "", "ticket": "", "updated_at": ""]) { $1 }
        root["mrs"] = mrs
        let value = try CompanionFeed.decode(try JSONSerialization.data(withJSONObject: root))
        let rows = CompanionBoard.mrs(feed: value, raw: nil)
        let full = try #require(rows[0].feedRow), empty = try #require(rows[1].feedRow)
        #expect(CompanionFeed.text(full.author) == "alandomio" && CompanionFeed.text(full.blocker) == "Two threads open" && CompanionFeed.text(full.next) == "Reply to Klemens" && CompanionFeed.text(full.ticket) == "IN-2566")
        #expect(CompanionFeed.date(full.updatedAt) == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        #expect(CompanionFeed.text(empty.author) == nil && CompanionFeed.text(empty.headline) == nil && CompanionFeed.date(empty.updatedAt) == nil)
        #expect(value.skipped.isEmpty)
        let plain = try CompanionFeed.decode(Data(CompanionFixture.json(generatedAt: t0).utf8))
        #expect(plain.mrs[0].author == nil && plain.skipped.isEmpty)  // the fields are optional
        #expect(CompanionFeed.date("not a date") == nil)
    }

    /// Every id a button can write must come from the feed itself (the bridge drops unknown ids as stale).
    func assertClicksUseFeedIDs(_ feed: CompanionFeed) throws {
        for decision in feed.decisions {
            for (index, option) in decision.options.enumerated() {
                let id = try #require(option.actionId, "option without action_id in \(decision.id)")
                let click = try #require(CompanionAnswer.click(decisionID: decision.id, option: option, optionIndex: index, text: ""))
                #expect(click.actionID == id && click.target == decision.id)
            }
        }
        for mr in feed.mrs {
            let ids = Set(mr.actions.map(\.id))
            for action in mr.actions { #expect(CompanionAnswer.rowClick(action: action, ref: mr.ref).actionID == action.id && ids.contains(action.id)) }
            if !mr.drafts.isEmpty, let post = mr.postAction {
                let click = try #require(CompanionAnswer.postClick(mr: mr, text: "edited text\n"))
                #expect(ids.contains(click.actionID) && click.actionID == post.id && click.target == mr.ref && click.draftText == "edited text\n")
            }
            if let recommended = CompanionRecommendation.actionID(in: mr.actions, texts: [mr.label]) {
                #expect(ids.contains(recommended) && CompanionRecommendation.ordered(mr.actions, recommended: recommended).first?.id == recommended)
            }
        }
        for ticket in feed.tickets {
            let ids = Set(ticket.actions.map(\.id))
            if let recommended = CompanionRecommendation.actionID(in: ticket.actions, texts: [ticket.finish?.step]) { #expect(ids.contains(recommended)) }
        }
    }
    @Test func everyButtonActionIDExistsInTheFixtureFeed() throws {
        try assertClicksUseFeedIDs(try feed())
        let fixture = try feed()
        #expect(fixture.mrs[0].postAction?.id == "mr-12-post")
        #expect(CompanionAnswer.postClick(mr: fixture.mrs[1], text: "x") == nil)  // no post action in the feed: no click
    }
    @Test func everyButtonActionIDExistsInTheRealFeedWhenPresent() throws {
        guard let data = FileManager.default.contents(atPath: NSString(string: CompanionFeed.defaultPath).expandingTildeInPath) else { return }
        try assertClicksUseFeedIDs(try CompanionFeed.decode(data))
    }
    @Test func recommendationPrefersTheActionTheRowNamesAndSkipsOutwardAndQuietOnes() {
        let actions: [CompanionFeed.Action] = [
            .init(id: "r.resolve-and-merge", label: "Resolve and merge", outward: true), .init(id: "r.fix-the-threads", label: "Fix the threads", outward: false),
            .init(id: "r.post-drafted-reply", label: "Post drafted reply", outward: true), .init(id: "r.wait-what", label: "Wait, what?", outward: false), .init(id: "r.nevermind", label: "Nevermind", outward: false)]
        #expect(CompanionRecommendation.actionID(in: actions, texts: ["Change two monitor settings, then reply", "Fix the open threads"]) == "r.fix-the-threads")
        #expect(CompanionRecommendation.actionID(in: actions, texts: ["Nothing matches here"]) == "r.fix-the-threads")  // first harmless action
        #expect(CompanionRecommendation.actionID(in: Array(actions.filter(\.outward)), texts: ["merge"]) == nil)
        #expect(CompanionRecommendation.ordered(actions, recommended: "r.fix-the-threads").map(\.id).first == "r.fix-the-threads")
    }
    @Test func receiptsFollowTheRepliesFolderAndWarnAfterTwoMinutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipts-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox"), replies = root.appendingPathComponent("replies")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try CompanionInbox.file(CompanionClick(actionID: "a", target: "t", now: t0, key: "key-12345678"), inbox: inbox.path, now: t0)
        func status(_ offset: TimeInterval) -> CompanionReceipt { CompanionReceipt.resolve(note: note, key: "key-12345678", repliesDirectory: replies, sentAt: t0, now: t0.addingTimeInterval(offset)) }
        #expect(status(30).status == .sent && status(119).status == .sent)
        #expect(status(121).status == .waiting)
        func reply(_ status: String, text: String? = nil) throws {
            var object: [String: Any] = ["schema": "companion-reply.v1", "idempotency_key": "key-12345678", "note_id": "n1", "status": status, "updated_at": "2027-01-15T08:00:00Z"]
            if let text { object["text"] = text }
            try JSONSerialization.data(withJSONObject: object).write(to: replies.appendingPathComponent("key-12345678.json"))
        }
        try reply("queued"); #expect(status(600).status == .queued)  // a receipt exists, so no warning
        try reply("picked_up"); #expect(status(600).status == .pickedUp)
        try reply("done", text: "Posted."); #expect(status(5) == CompanionReceipt(status: .done, text: "Posted."))
        try reply("rejected", text: "unknown action"); #expect(status(5) == CompanionReceipt(status: .rejected, text: "unknown action"))
        #expect(CompanionReceipt.repliesDirectory(feedPath: "/x/companion/feed.json").path == "/x/companion/replies")
    }

    @Test func decisionRecommendationFindsTheOptionByLabelNumberOrWords() {
        func option(_ label: String) -> CompanionFeed.Option { .init(label: label, consequence: "c", actionId: nil, outward: nil, standard: nil) }
        let options = [option("retry the two CI jobs that failed on a runner TLS fault"), option("do not merge")]
        #expect(CompanionRecommendation.optionIndex(recommendation: "option 1, retry then merge.", options: options) == 0)
        #expect(CompanionRecommendation.optionIndex(recommendation: "Option 2", options: options) == 1)
        #expect(CompanionRecommendation.optionIndex(recommendation: "do not merge", options: options) == 1)
        #expect(CompanionRecommendation.optionIndex(recommendation: "retry the failed jobs first", options: options) == 0)
        #expect(CompanionRecommendation.optionIndex(recommendation: "option 7", options: options) == nil)
        #expect(CompanionRecommendation.optionIndex(recommendation: "", options: options) == nil)
    }

    @Test func decisionDateAgeAndSortOrder() throws {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(CompanionFixture.json(generatedAt: t0).utf8)) as? [String: Any])
        var decisions = try #require(root["decisions"] as? [[String: Any]])
        var third = decisions[0]; third["id"] = "dec-3"; decisions.append(third)
        decisions[0]["created_at"] = "2026-09-11"; decisions[1]["created_at"] = "not a date"; decisions[2]["created_at"] = "2026-08-01"
        root["decisions"] = decisions
        let value = try CompanionFeed.decode(try JSONSerialization.data(withJSONObject: root))
        #expect(value.skipped.isEmpty && value.decisions.count == 3)
        let day = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        #expect(value.decisions[0].ageDays(now: day) == 52 && value.decisions[2].ageDays(now: day) == 93)
        #expect(value.decisions[1].created == nil && value.decisions[1].ageDays(now: day) == nil)
        #expect(DecisionOrder.feed.apply(value.decisions).map(\.id) == ["dec-1", "dec-2", "dec-3"])
        #expect(DecisionOrder.oldestFirst.apply(value.decisions).map(\.id) == ["dec-3", "dec-1", "dec-2"])  // undated last
        #expect(try CompanionFeed.decode(Data(CompanionFixture.json(generatedAt: t0).utf8)).decisions[0].createdAt == nil)
    }
}

@Suite struct StandardOptionTests {
    @Test func standardFlagIsOptionalAndSplitsOptions() throws {
        let json = #"{"label":"Drop it","consequence":"x","action_id":"d.opt-drop","standard":true}"#.data(using: .utf8)!
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let standard = try decoder.decode(CompanionFeed.Option.self, from: json)
        #expect(standard.isStandard)
        let plain = try decoder.decode(CompanionFeed.Option.self, from: #"{"label":"Go","consequence":"x"}"#.data(using: .utf8)!)
        #expect(!plain.isStandard)
    }
}

@Suite struct DecisionKeysTests {
    @Test func lettersPickOptionsThatExist() {
        #expect(DecisionKeys.command(.character("a"), optionCount: 2, typing: false) == .pick(0))
        #expect(DecisionKeys.command(.character("B"), optionCount: 2, typing: false) == .pick(1))
        #expect(DecisionKeys.command(.character("c"), optionCount: 2, typing: false) == nil)
        #expect(DecisionKeys.command(.character("1"), optionCount: 2, typing: false) == nil)
        #expect(DecisionKeys.command(.character("ab"), optionCount: 2, typing: false) == nil)
    }
    @Test func arrowsAndEnterMapAndTypingBlocksEverything() {
        #expect(DecisionKeys.command(.left, optionCount: 2, typing: false) == .previous)
        #expect(DecisionKeys.command(.right, optionCount: 2, typing: false) == .next)
        #expect(DecisionKeys.command(.up, optionCount: 2, typing: false) == .selectUp)
        #expect(DecisionKeys.command(.down, optionCount: 2, typing: false) == .selectDown)
        #expect(DecisionKeys.command(.enter, optionCount: 2, typing: false) == .confirm)
        for key in [DecisionKeys.Key.left, .right, .up, .down, .enter, .character("a")] { #expect(DecisionKeys.command(key, optionCount: 2, typing: true) == nil) }
    }
    @Test func selectionStartsOnRecommendedAndStaysInRange() {
        #expect(DecisionKeys.moved(selected: nil, recommended: 1, by: 0, count: 3) == 1)
        #expect(DecisionKeys.moved(selected: nil, recommended: 1, by: 1, count: 3) == 2)
        #expect(DecisionKeys.moved(selected: 2, recommended: 1, by: 1, count: 3) == 2)
        #expect(DecisionKeys.moved(selected: 0, recommended: nil, by: -1, count: 3) == 0)
        #expect(DecisionKeys.moved(selected: nil, recommended: nil, by: 1, count: 3) == 1)
        #expect(DecisionKeys.letter(0) == "A" && DecisionKeys.letter(2) == "C")
    }
}

@Suite struct SummaryDecodingTests {
    private func decision(_ extra: String) throws -> CompanionFeed.Decision {
        let json = #"{"id":"d","title":"T","project":"p","why_now":"because","recommendation":"","options":[],"links":[],"urgent":false"# + extra + "}"
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CompanionFeed.Decision.self, from: json.data(using: .utf8)!)
    }
    @Test func olderFeedsHaveNoSummaryAndFallBackToWhyNow() throws {
        let old = try decision("")
        #expect(old.summaryParts.isEmpty)
        #expect(old.contextText == "because")
    }
    @Test func summaryKeepsFourPartsWithTextAndFullContextWins() throws {
        let parts = (1...6).map { #"{"heading":"H\#($0)","text":"t\#($0)"}"# }.joined(separator: ",") + #",{"heading":"Empty","text":"  "}"#
        let new = try decision(#","summary":["# + parts + #"],"full_context":"Line one.\n\nLine two.""#)
        #expect(new.summaryParts.count == 4)
        #expect(new.summaryParts.first?.heading == "H1")
        #expect(new.contextText.hasPrefix("Line one."))
        let noHeading = try decision(#","summary":[{"text":"only text"}]"#)
        #expect(noHeading.summaryParts.first?.heading == nil)
    }
}

@Suite struct MRCardNavigationTests {
    @Test func arrowKeysMapToPreviousAndNextAndMRCardsWrap() {
        #expect(DecisionKeys.command(.left, optionCount: 0, typing: false) == .previous)
        #expect(DecisionKeys.command(.right, optionCount: 0, typing: false) == .next)
        #expect(DecisionKeys.command(.left, optionCount: 0, typing: true) == nil)
        #expect(Pager.move(0, by: -1, count: 48, wrap: true) == 47)
        #expect(Pager.move(47, by: 1, count: 48, wrap: true) == 0)
        #expect(Pager.move(5, by: 1, count: 48, wrap: true) == 6)
        #expect(Pager.move(0, by: 1, count: 0, wrap: true) == 0)
        #expect(Pager.label(0, count: 48) == (1, 48))
        #expect(Pager.label(99, count: 3) == (3, 3))
    }
    @Test func draftPagerStopsAtItsEnds() {
        #expect(Pager.move(0, by: -1, count: 3, wrap: false) == 0)
        #expect(Pager.move(2, by: 1, count: 3, wrap: false) == 2)
        #expect(Pager.move(0, by: 1, count: 3, wrap: false) == 1)
        #expect(!Pager.canMove(0, by: -1, count: 3))
        #expect(Pager.canMove(0, by: 1, count: 3))
        #expect(!Pager.canMove(2, by: 1, count: 3))
        #expect(!Pager.canMove(0, by: 1, count: 1))
    }
    @Test func ticketIdAndLinkComeOnlyFromTheFeed() {
        #expect(MRTicket.identifier(in: "IN-2566 · In Progress") == "IN-2566")
        #expect(MRTicket.identifier(in: "no ticket here") == nil)
        #expect(MRTicket.identifier(in: nil) == nil)
        #expect(MRTicket.url(identifier: "IN-1", feedURL: "https://linear.app/pp/issue/IN-1", tickets: [])?.host == "linear.app")
        #expect(MRTicket.url(identifier: "IN-1", feedURL: "http://evil.example/x", tickets: []) == nil)
        #expect(MRTicket.url(identifier: "IN-1", feedURL: nil, tickets: []) == nil)
    }
    @Test func draftsDecodeTheCommentTheyAnswer() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let withQuote = try decoder.decode(CompanionFeed.Draft.self, from: #"{"id":"d1","target_url":"https://x","text":"ok","reply_to":{"author":"Sadmi","text":"use max:","location":"a.yaml line 14"}}"#.data(using: .utf8)!)
        #expect(withQuote.replyTo?.author == "Sadmi" && withQuote.replyTo?.text == "use max:")
        let plain = try decoder.decode(CompanionFeed.Draft.self, from: #"{"id":"d1","target_url":"https://x","text":"ok"}"#.data(using: .utf8)!)
        #expect(plain.replyTo == nil)
    }
}

@Suite struct MROrderTests {
    private func rows(_ ranks: [Int?], steps: [String?] = []) throws -> [BoardMR] {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(CompanionFixture.json(generatedAt: Date()).utf8)) as? [String: Any])
        let base = try #require((root["mrs"] as? [[String: Any]])?.first)
        var list: [[String: Any]] = []
        for (offset, rank) in ranks.enumerated() {
            var row = base; row["ref"] = "r\(offset) !\(offset + 1)"; row["url"] = "https://gitlab.example/mr/\(offset)"
            if let rank { row["close_rank"] = rank }
            if offset < steps.count, let step = steps[offset] { row["close_step"] = step }
            list.append(row)
        }
        root["mrs"] = list
        return CompanionBoard.mrs(feed: try CompanionFeed.decode(try JSONSerialization.data(withJSONObject: root)), raw: nil)
    }
    @Test func cardsSortByCloseRankThenFeedOrderWithUnrankedLast() throws {
        let sorted = try rows([5, nil, 1, 5, 2]).map(\.ref)
        #expect(sorted == ["r2 !3", "r4 !5", "r0 !1", "r3 !4", "r1 !2"])
    }
    @Test func feedsWithoutRanksKeepTheirOrder() throws {
        #expect(try rows([nil, nil, nil]).map(\.ref) == ["r0 !1", "r1 !2", "r2 !3"])
    }
    @Test func stepLabelsAreNormalisedAndMissingOnesHidden() throws {
        #expect(MROrder.stepLabel("merge") == "Merge")
        #expect(MROrder.stepLabel("Final_Check") == "Final check")
        #expect(MROrder.stepLabel("your step") == "Your step")
        #expect(MROrder.stepLabel("  ") == nil && MROrder.stepLabel(nil) == nil)
        #expect(try rows([1], steps: ["waiting"])[0].feedRow?.closeStep == "waiting")
    }
}
