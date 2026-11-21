import Foundation

// The Workers tab (ShipDeck 1.1, 036). Everything here is pure: it reads the text of `state/<id>.meta`,
// `state/<id>.status` and one `fm-crew-state.sh` line, and decides where a worker is listed. Running the
// firstmate verbs is `WorkerRunner`; drawing is `WorkersView`.

/// `state/<id>.meta`: `key=value` lines.
public struct WorkerMeta: Equatable, Sendable {
    public let id: String
    public var kind = "", harness = "", model = "", effort = "", worktree = "", project = "", backend = "", branch = "", window = ""
    public var remoteHost: String?, paneID: String?, herdrSession: String?, herdrWorkspace: String?, herdrTab: String?
    public init(id: String) { self.id = id }

    public static func parse(id: String, text: String) -> WorkerMeta {
        var meta = WorkerMeta(id: id)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces), value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "kind": meta.kind = value
            case "harness": meta.harness = value
            case "model": meta.model = value
            case "effort": meta.effort = value
            case "worktree": meta.worktree = value
            case "project": meta.project = value
            case "backend": meta.backend = value
            case "branch": meta.branch = value
            case "window": meta.window = value
            case "remote_host": if !value.isEmpty { meta.remoteHost = value }
            case "herdr_pane_id": if !value.isEmpty { meta.paneID = value }
            case "herdr_session": if !value.isEmpty { meta.herdrSession = value }
            case "herdr_workspace_id": if !value.isEmpty { meta.herdrWorkspace = value }
            case "herdr_tab_id": if !value.isEmpty { meta.herdrTab = value }
            default: break
            }
        }
        return meta
    }
    /// A second mate on another host: listed read-only, never controlled from here.
    public var isRemote: Bool { remoteHost != nil || window.hasPrefix("remote:") }
}

/// One line of `state/<id>.status`: `verb [at=epoch] [key=k]: text`.
public struct StatusEvent: Equatable, Sendable {
    public let verb: String
    public let at: Date?
    public let key: String?
    public let text: String
}

public enum StatusLog {
    static let verbs: Set<String> = ["working", "paused", "done", "needs-decision", "blocked", "failed", "note", "progress", "resolved", "pending-reply", "captain-held"]

    /// Continuation lines (no recognised verb at the start) belong to the event above them.
    public static func parse(_ text: String) -> [StatusEvent] {
        var events: [StatusEvent] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            // An ISO timestamp may precede the verb on older logs: "2026-10-08T14:44:57Z paused: ..."
            var stamped: Date?
            if let space = line.firstIndex(of: " "), line.hasPrefix("20"), let date = CompanionFeed.date(String(line[..<space])) { stamped = date; line = String(line[line.index(after: space)...]) }
            let verb = String(line.prefix { $0.isLetter || $0 == "-" })
            guard verbs.contains(verb) else {
                if !events.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty, let last = events.popLast() {
                    events.append(StatusEvent(verb: last.verb, at: last.at, key: last.key, text: last.text + "\n" + line))
                }
                continue
            }
            var rest = line.dropFirst(verb.count)
            var at = stamped, key: String?
            while rest.first == " " { rest = rest.dropFirst() }
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if inner.hasPrefix("at="), let seconds = Double(inner.dropFirst(3)) { at = Date(timeIntervalSince1970: seconds) }
                else if inner.hasPrefix("key=") { key = String(inner.dropFirst(4)) }
                rest = rest[rest.index(after: close)...]
                while rest.first == " " { rest = rest.dropFirst() }
            }
            if rest.first == ":" { rest = rest.dropFirst() }
            events.append(StatusEvent(verb: verb, at: at, key: key, text: rest.trimmingCharacters(in: .whitespaces)))
        }
        return events
    }

    /// The needs-decision and blocked events nobody has closed: a `resolved` or `captain-held` with the same key closes one.
    public static func openDecisions(_ events: [StatusEvent]) -> [StatusEvent] {
        var open: [StatusEvent] = []
        for event in events {
            switch event.verb {
            case "needs-decision", "blocked": open.removeAll { $0.key == event.key && event.key != nil }; open.append(event)
            case "resolved", "captain-held": if let key = event.key { open.removeAll { $0.key == key } }
            // The worker went on (or finished) after asking: the ask is history. A held decision lives in the feed.
            case "done", "working", "paused", "failed": open.removeAll()
            default: break
            }
        }
        return open
    }
}

/// The one line of `fm-crew-state.sh`: `state: working · source: pane · harness busy`.
public struct CrewState: Equatable, Sendable {
    public enum Kind: String, Sendable { case working, parked, done, blocked, paused, failed, unknown }
    public let kind: Kind, source: String, detail: String
    public init(kind: Kind, source: String = "", detail: String = "") { self.kind = kind; self.source = source; self.detail = detail }

    public static func parse(_ output: String) -> CrewState? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("state:") }) else { return nil }
        let parts = line.components(separatedBy: " · ")
        let kind = Kind(rawValue: parts[0].replacingOccurrences(of: "state:", with: "").trimmingCharacters(in: .whitespaces)) ?? .unknown
        let source = parts.count > 1 ? parts[1].replacingOccurrences(of: "source:", with: "").trimmingCharacters(in: .whitespaces) : ""
        return CrewState(kind: kind, source: source, detail: parts.dropFirst(2).joined(separator: " · "))
    }
}

/// `fm-control.sh <task> prompt`: the exact prompt a stuck worker shows. Tolerant of the key names the verb may settle on.
public struct WorkerPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable { public let id: String, label: String }
    public let text: String
    public let options: [Option]
    public let sha: String

    public static func parse(_ json: String) -> WorkerPrompt? {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ keys: [String]) -> String? { keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty } }
        guard let text = string(["prompt", "text", "prompt_text"]), let sha = string(["sha", "prompt_sha", "expect_prompt_sha"]) else { return nil }
        let raw = (object["options"] as? [Any]) ?? []
        let options = raw.enumerated().compactMap { index, value -> Option? in
            if let label = value as? String { return Option(id: String(index + 1), label: label) }
            guard let dict = value as? [String: Any] else { return nil }
            let id = (dict["id"] as? String) ?? (dict["key"] as? String) ?? (dict["option"] as? String) ?? (dict["id"] as? Int).map(String.init) ?? String(index + 1)
            guard let label = (dict["label"] as? String) ?? (dict["text"] as? String) else { return nil }
            return Option(id: id, label: label)
        }
        return WorkerPrompt(text: text, options: options, sha: sha)
    }
}

public enum WorkerGroup: String, CaseIterable, Sendable, Identifiable {
    case needsYou, working, done, waiting, stale, remote
    public var id: String { rawValue }
}

/// Why a worker is in "Needs you".
public enum WorkerNeed: Equatable, Sendable {
    case stuckPrompt, decision(String), cleanupRefused(String)
}

/// One worker as the Workers tab lists it.
public struct Worker: Identifiable, Equatable, Sendable {
    public let meta: WorkerMeta
    public let crew: CrewState?
    public let events: [StatusEvent]
    public let openDecisions: [StatusEvent]
    public let lastActivity: Date?
    /// Review comment drafts of this worker that were never posted (from the feed).
    public let unpostedDrafts: Int
    /// The note of a failed `worker.cleanup` command, when firstmate refused to clean this worker up.
    public let refusedCleanup: String?
    public let group: WorkerGroup
    public var id: String { meta.id }

    public init(meta: WorkerMeta, crew: CrewState?, events: [StatusEvent], unpostedDrafts: Int = 0, refusedCleanup: String? = nil, feedDecisions: [String] = [], now: Date = Date()) {
        self.meta = meta; self.crew = crew; self.events = events; self.unpostedDrafts = unpostedDrafts; self.refusedCleanup = refusedCleanup
        openDecisions = StatusLog.openDecisions(events) + feedDecisions.map { StatusEvent(verb: "needs-decision", at: nil, key: "feed", text: $0) }
        lastActivity = events.compactMap(\.at).max()
        group = Self.classify(meta: meta, crew: crew, events: events, open: openDecisions, refused: refusedCleanup, last: lastActivity, now: now)
    }

    static func classify(meta: WorkerMeta, crew: CrewState?, events: [StatusEvent], open: [StatusEvent], refused: String?, last: Date?, now: Date) -> WorkerGroup {
        if meta.isRemote { return .remote }
        if refused != nil || crew?.kind == .blocked { return .needsYou }
        let running = crew?.kind == .working
        if !running, !open.isEmpty, crew?.kind != .done { return .needsYou }
        if running { return .working }
        let finished = crew?.kind == .done || (crew == nil || crew?.kind == .unknown) && events.last(where: { !["note", "progress", "resolved", "pending-reply", "captain-held"].contains($0.verb) })?.verb == "done"
        if finished { return open.isEmpty ? .done : .needsYou }
        if let last, now.timeIntervalSince(last) > WorkerBoard.staleAfter { return .stale }
        if crew?.kind == .paused || crew?.kind == .parked || events.last?.verb == "paused" { return .waiting }
        return last == nil ? .stale : .waiting
    }

    /// What the worker needs from the captain, most pressing first.
    public var needs: [WorkerNeed] {
        var result: [WorkerNeed] = []
        if crew?.kind == .blocked { result.append(.stuckPrompt) }
        for decision in openDecisions { result.append(.decision(decision.text)) }
        if let refusedCleanup { result.append(.cleanupRefused(refusedCleanup)) }
        return result
    }

    /// The finished worker's verdict: the first line of its last `done` event, long text cut at a word.
    public var verdict: String? {
        guard let done = events.last(where: { $0.verb == "done" }) else { return nil }
        return WorkerBoard.firstLine(done.text, limit: 220)
    }
    /// Sweeping counts as the captain having seen the result, so a worker with unposted drafts or an open decision is never swept.
    public var sweepBlocker: String? {
        if unpostedDrafts > 0 { return unpostedDrafts == 1 ? "1 review comment is not posted yet" : "\(unpostedDrafts) review comments are not posted yet" }
        if !openDecisions.isEmpty { return "a decision is still open" }
        return nil
    }
    public var sweepable: Bool { (group == .done || group == .stale) && sweepBlocker == nil && !meta.isRemote }
    public var activity: String { events.last(where: { !["note", "progress", "resolved"].contains($0.verb) }).map { WorkerBoard.firstLine($0.text, limit: 160) } ?? "" }
}

public enum WorkerBoard {
    public static let staleAfter: TimeInterval = 24 * 3600

    public static func firstLine(_ text: String, limit: Int) -> String {
        let line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        let cut = String(line.prefix(limit)), space = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) } ?? limit
        return String(cut.prefix(max(space, limit / 2))).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    /// Reads one worker's meta and status from `<home>/state`. nil when there is no meta.
    public static func load(id: String, home: String) -> (meta: WorkerMeta, events: [StatusEvent])? {
        let state = URL(fileURLWithPath: home).appendingPathComponent("state")
        guard let metaText = try? String(contentsOf: state.appendingPathComponent(id + ".meta"), encoding: .utf8) else { return nil }
        let log = (try? String(contentsOf: state.appendingPathComponent(id + ".status"), encoding: .utf8)) ?? ""
        return (WorkerMeta.parse(id: id, text: metaText), StatusLog.parse(log))
    }
    public static func ids(home: String) -> [String] {
        let state = URL(fileURLWithPath: home).appendingPathComponent("state")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []
        return names.filter { $0.hasSuffix(".meta") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Unposted review drafts per worker task id: the MR cards' remaining drafts that name their source report's task.
    public static func unposted(mrs: [BoardMR], ledger: CommandLedger, discarded: Set<String> = []) -> [String: Int] {
        var result: [String: Int] = [:]
        for mr in mrs {
            let perDraft = ReviewDrafts.isPerDraft(mr.drafts, actions: mr.actions)
            let left = perDraft ? ReviewDrafts.remaining(mr.drafts, target: mr.ref, actions: mr.actions, ledger: ledger, discarded: discarded) : mr.drafts
            for draft in left { if let source = draft.source, !source.isEmpty { result[source, default: 0] += 1 } }
        }
        return result
    }

    /// Open feed decisions per worker: a held decision's id is its task id, or the worker's id plus a suffix (rv-pi-2050-comment).
    public static func feedDecisions(_ decisions: [(id: String, title: String)], workers: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for decision in decisions {
            for id in workers where decision.id == id || decision.id.hasPrefix(id + "-") { result[id, default: []].append(decision.title) }
        }
        return result
    }

    /// The note of the newest `worker.cleanup` command for this task when it failed (firstmate refused).
    public static func refusedCleanup(task: String, ledger: CommandLedger) -> String? {
        guard let latest = ledger.latest(target: WorkerActions.target(task), actionID: WorkerActions.cleanup), latest.state == .failed else { return nil }
        return latest.note ?? "cleanup refused"
    }

    public static let order: [WorkerGroup] = WorkerGroup.allCases
    public static func grouped(_ workers: [Worker]) -> [(WorkerGroup, [Worker])] {
        order.compactMap { group in
            let members = workers.filter { $0.group == group }.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            return members.isEmpty ? nil : (group, members)
        }
    }
}

/// Click ids for what firstmate does for ShipDeck. The executor split: refresh, peek, interrupt, exit, relaunch and
/// answer run in the app (`WorkerRunner`); these go through the click inbox.
public enum WorkerActions {
    public static let sweep = "worker.sweep", cleanup = "worker.cleanup", discard = "worker.discard", steer = "worker.steer"
    public static func target(_ task: String) -> String { "worker:" + task }
    public static func task(of target: String) -> String? { target.hasPrefix("worker:") ? String(target.dropFirst(7)) : nil }

    /// Sweep: the verdict travels as the text so firstmate records exactly what the captain saw.
    public static func sweepClick(_ worker: Worker, now: Date = Date()) -> CompanionClick? {
        guard worker.sweepable else { return nil }
        return CompanionClick(actionID: sweep, target: target(worker.id), draftText: worker.verdict ?? worker.activity, now: now)
    }
    public static func steerClick(task: String, text: String, now: Date = Date()) -> CompanionClick? {
        var typed = text
        while let last = typed.last, last.isWhitespace || last.isNewline { typed.removeLast() }
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CompanionClick(actionID: steer, target: target(task), draftText: typed, now: now)
    }
    /// What a discard throws away, for the confirm dialog: the worktree, the branch, and what firstmate said it refused over.
    public static func discardLoss(_ worker: Worker) -> [String] {
        var lines: [String] = []
        if !worker.meta.worktree.isEmpty { lines.append("The local copy at " + worker.meta.worktree) }
        if !worker.meta.branch.isEmpty { lines.append("Its branch " + worker.meta.branch + " (not removed from the remote)") }
        if let note = worker.refusedCleanup { lines.append("Everything firstmate refused to clean up over: " + WorkerBoard.firstLine(note, limit: 300)) }
        lines.append("Its terminal pane and its state record")
        return lines
    }
}

/// The verbs this home's `fm-control.sh` knows. `prompt` and `answer` land in their own firstmate change; until
/// then the card shows the pane tail and an Open button.
public enum WorkerVerbs {
    public static func supports(_ verb: String, controlScript text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && (trimmed.hasPrefix(verb + ")") || trimmed.hasPrefix(verb + "|") || trimmed.contains("|" + verb + ")") || trimmed == verb)
        }
    }
}
