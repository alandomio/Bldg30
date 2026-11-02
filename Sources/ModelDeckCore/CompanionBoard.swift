import Foundation

public struct BoardMR: Equatable, Sendable, Identifiable {
    public var id: String { ref }
    public let ref: String, title: String, role: String
    public let pipeline: String?
    public let label: String, nextOwner: String
    public let url: URL
    public let openThreads: Int?
    /// nil when firstmate never judged this MR (it only exists in the raw poll).
    public let verdict: String?
    public let verdictStale: Bool
    public let drafts: [CompanionFeed.Draft]
    public let actions: [CompanionFeed.Action]
    /// Last GitLab activity, known only when the app polled it.
    public let updatedAt: Date?
}

public struct BoardTicketRow: Equatable, Sendable, Identifiable {
    public var id: String { identifier }
    public let identifier: String, title: String, status: String
    public let url: URL
    public let finish: CompanionFeed.Finish?
    public let finishStale: Bool
    public let linkedMrs: [String]
    public let actions: [CompanionFeed.Action]
}

/// Puts the app's own newer polls over the firstmate feed and flags verdicts the raw state has outrun.
public enum CompanionBoard {
    static func key(_ url: URL) -> String { url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }

    public static func mrs(feed: CompanionFeed?, raw: RawBoard?) -> [BoardMR] {
        var rawByURL = Dictionary(raw?.mrs.map { (key($0.url), $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var rows: [BoardMR] = []
        for mr in feed?.mrs ?? [] {
            var pipeline: String? = mr.pipeline, threads: Int? = mr.openThreads, stale = false
            let updated = raw?.gitlabOK == true ? rawByURL[key(mr.url)]?.updatedAt : nil
            if let raw, raw.gitlabOK, let generated = feed?.generatedAt, raw.fetchedAt > generated {
                if let live = rawByURL[key(mr.url)] {
                    pipeline = live.pipeline; threads = live.openThreads
                    stale = live.pipeline != mr.pipeline || live.openThreads != mr.openThreads || live.updatedAt > generated
                } else { stale = true }
            }
            rawByURL[key(mr.url)] = nil
            rows.append(BoardMR(ref: mr.ref, title: mr.title, role: mr.role, pipeline: pipeline, label: mr.label, nextOwner: mr.nextOwner, url: mr.url,
                                openThreads: threads, verdict: mr.verdict, verdictStale: stale, drafts: mr.drafts, actions: mr.actions, updatedAt: updated))
        }
        for live in raw?.mrs ?? [] where rawByURL[key(live.url)] != nil {
            rows.append(BoardMR(ref: live.ref, title: live.title, role: live.role, pipeline: live.pipeline, label: "", nextOwner: "", url: live.url,
                                openThreads: live.openThreads, verdict: nil, verdictStale: false, drafts: [], actions: [], updatedAt: live.updatedAt))
        }
        return rows
    }

    public static func tickets(feed: CompanionFeed?, raw: RawBoard?) -> [BoardTicketRow] {
        var live = Dictionary(raw?.tickets.map { ($0.identifier, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var rows: [BoardTicketRow] = []
        for ticket in feed?.tickets ?? [] {
            var status = ticket.status, stale = false
            if let raw, raw.linearOK, let generated = feed?.generatedAt, raw.fetchedAt > generated {
                if let current = live[ticket.identifier] {
                    status = current.state; stale = current.state != ticket.status || current.updatedAt > generated
                } else { stale = true }
            }
            live[ticket.identifier] = nil
            rows.append(BoardTicketRow(identifier: ticket.identifier, title: ticket.title, status: status, url: ticket.url, finish: ticket.finish,
                                       finishStale: stale, linkedMrs: ticket.linkedMrs, actions: ticket.actions))
        }
        for ticket in raw?.tickets ?? [] where live[ticket.identifier] != nil {
            rows.append(BoardTicketRow(identifier: ticket.identifier, title: ticket.title, status: ticket.state, url: ticket.url, finish: nil,
                                       finishStale: false, linkedMrs: [], actions: []))
        }
        return rows
    }
}

public enum CompanionDiff {
    /// Events between two polls, plus MRs that vanished and need a merged check. The first poll is a silent baseline.
    public static func events(old: RawBoard?, new: RawBoard, now: Date = Date()) -> (events: [CompanionEvent], vanished: [RawMR]) {
        guard let old else { return ([], []) }
        var events: [CompanionEvent] = []
        if old.gitlabOK && new.gitlabOK {
            let before = Dictionary(old.mrs.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
            for mr in new.mrs {
                guard let was = before[mr.ref] else {
                    if mr.role == "reviewer" { events.append(.init(kind: "review_requested", ref: mr.ref, source: "gitlab", state: "requested", now: now)) }
                    continue
                }
                if mr.pipeline != was.pipeline { events.append(.init(kind: "pipeline_changed", ref: mr.ref, source: "gitlab", state: mr.pipeline, now: now)) }
                if mr.openThreads > was.openThreads { events.append(.init(kind: "new_comment", ref: mr.ref, source: "gitlab", state: "threads=\(mr.openThreads)", now: now)) }
            }
        }
        if old.linearOK && new.linearOK {
            let before = Dictionary(old.tickets.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            for ticket in new.tickets where before[ticket.identifier].map({ $0.state != ticket.state }) == true {
                events.append(.init(kind: "ticket_state", ref: ticket.identifier, source: "linear", state: ticket.state, now: now))
            }
        }
        let gone = old.gitlabOK && new.gitlabOK ? old.mrs.filter { was in !new.mrs.contains { $0.ref == was.ref } } : []
        return (events, gone)
    }
}
