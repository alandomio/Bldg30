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
    public var postActionID: String? { CompanionFeed.postAction(of: actions)?.id }
    public let updatedAt: Date?
    /// The feed row the extra producer fields come from; nil for MRs only seen in the poll.
    public let feedRow: CompanionFeed.MergeRequest?
}

public struct BoardTicketRow: Equatable, Sendable, Identifiable {
    public var id: String { identifier }
    public let identifier: String, title: String, status: String
    public let url: URL
    public let finish: CompanionFeed.Finish?
    public let finishStale: Bool
    public let linkedMrs: [String]
    public let actions: [CompanionFeed.Action]
    public let decisionId: String?
    /// Structured Linear context from the feed; nil for tickets the feed does not describe.
    public let detail: CompanionFeed.TicketDetail?
}

/// Puts the app's own newer polls over the firstmate feed and flags verdicts the raw state has outrun.
public enum CompanionBoard {
    static func key(_ url: URL) -> String { url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }

    public static func mrs(feed: CompanionFeed?, raw: RawBoard?) -> [BoardMR] {
        var rawByURL = Dictionary(raw?.mrs.map { (key($0.url), $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var rows: [BoardMR] = []
        for mr in feed?.mrs ?? [] where !mr.isFinished {
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
                                openThreads: threads, verdict: mr.verdict, verdictStale: stale, drafts: mr.drafts, actions: mr.actions, updatedAt: updated, feedRow: mr))
        }
        for live in raw?.mrs ?? [] where rawByURL[key(live.url)] != nil {
            rows.append(BoardMR(ref: live.ref, title: live.title, role: live.role, pipeline: live.pipeline, label: "", nextOwner: "", url: live.url,
                                openThreads: live.openThreads, verdict: nil, verdictStale: false, drafts: [], actions: [], updatedAt: live.updatedAt, feedRow: nil))
        }
        return MROrder.apply(rows)
    }

    /// MRs the feed marks merged or closed: not shown as cards.
    public static func finishedMRs(feed: CompanionFeed?) -> [CompanionFeed.MergeRequest] { (feed?.mrs ?? []).filter(\.isFinished) }

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
                                       finishStale: stale, linkedMrs: ticket.linkedMrs, actions: ticket.actions, decisionId: ticket.decisionId, detail: ticket.detail))
        }
        for ticket in raw?.tickets ?? [] where live[ticket.identifier] != nil {
            rows.append(BoardTicketRow(identifier: ticket.identifier, title: ticket.title, status: ticket.state, url: ticket.url, finish: nil,
                                       finishStale: false, linkedMrs: [], actions: [], decisionId: nil, detail: nil))
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

public enum DecisionOrder: String, CaseIterable, Sendable { case feed, oldestFirst
    /// Urgent, then High, then the rest, each group in feed order (or oldest first with undated decisions last); the sort is stable.
    public func apply(_ decisions: [CompanionFeed.Decision]) -> [CompanionFeed.Decision] {
        let ordered = dated(decisions)
        return ordered.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level < b.element.level : a.offset < b.offset
        }.map(\.element)
    }
    private func dated(_ decisions: [CompanionFeed.Decision]) -> [CompanionFeed.Decision] {
        guard self == .oldestFirst else { return decisions }
        return decisions.enumerated().sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// MR cards stay in the producer's order: by `close_rank` (rows without one last), ties and unranked rows in feed order.
public enum MROrder {
    public static func apply(_ rows: [BoardMR]) -> [BoardMR] {
        rows.enumerated().sorted { a, b in
            let ra = a.element.feedRow?.closeRank ?? Int.max, rb = b.element.feedRow?.closeRank ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
    /// The small step label: Merge, Approve, Final check, Your step, Review or Waiting, from `close_step`; other text is shown as sent, empty gives nil.
    public static func stepLabel(_ step: String?) -> String? {
        guard let text = CompanionFeed.text(step) else { return nil }
        let known: [String: String] = ["merge": "Merge", "approve": "Approve", "final check": "Final check", "final_check": "Final check", "final-check": "Final check",
                                       "your step": "Your step", "your_step": "Your step", "your-step": "Your step", "review": "Review", "waiting": "Waiting"]
        return known[text.lowercased()] ?? String(text.prefix(24))
    }
}

/// Decisions that still wait for the user: a decision whose Drop click went out leaves the list at once.
public enum OpenDecisions {
    public static func isDropped(_ decision: CompanionFeed.Decision, ledger: CommandLedger) -> Bool {
        ledger.commands.contains { $0.target == decision.id && $0.actionID.hasSuffix(".opt-drop") && $0.state != .failed }
    }
    /// Feed decisions minus the dropped ones; a failed Drop keeps the decision in the list.
    public static func filter(_ decisions: [CompanionFeed.Decision], ledger: CommandLedger) -> [CompanionFeed.Decision] {
        decisions.filter { !isDropped($0, ledger: ledger) }
    }
}
