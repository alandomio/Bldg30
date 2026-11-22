import Foundation

/// Reader for `companion-feed.v1`, a JSON file a companion tool writes and the app only renders.
public struct CompanionFeed: Decodable, Equatable, Sendable {
    public static let schema = "companion-feed.v1"
    /// The producer refreshes every 5 minutes; three missed refreshes count as stale.
    public static let staleAfter: TimeInterval = 15 * 60
    public static let verdicts: Set<String> = ["close", "notyet", "blocked", "hold"]
    public static let roles: Set<String> = ["author", "reviewer"]

    public struct Option: Decodable, Equatable, Sendable { public let label: String; public let consequence: String; public let actionId: String?; public let outward: Bool?; public let standard: Bool?
        public var isStandard: Bool { standard ?? false } }
    public struct Decision: Decodable, Equatable, Sendable, Identifiable {
        public let id: String, title: String, project: String, whyNow: String, recommendation: String
        public let options: [Option]
        public let links: [URL]
        public let urgent: Bool
        /// Optional `priority`: "urgent", "high" or "normal". Without it, `urgent: true` means urgent.
        public let priority: String?
        public var level: DecisionPriority {
            switch priority?.lowercased() {
            case "urgent": return .urgent
            case "high": return .high
            case "normal": return .normal
            default: return urgent ? .urgent : .normal
            }
        }
        /// The day the decision was raised, YYYY-MM-DD; optional.
        public let createdAt: String?
        /// Optional short headed paragraphs and the original record, both written by the producer.
        public let summary: [SummaryPart]?
        public let fullContext: String?
        /// The summary parts that have text, at most four; empty when the feed has none.
        public var summaryParts: [SummaryPart] { Array((summary ?? []).filter { CompanionFeed.text($0.text) != nil }.prefix(4)) }
        /// The original record, or `why_now` while the producer sends none.
        /// Without a headed summary, the plain legacy reason is split into one here.
        var legacy: (title: String, parts: [SummaryPart])? {
            summaryParts.isEmpty ? LegacyReason.parse(CompanionFeed.text(fullContext) ?? whyNow, rowTitle: title, id: id) : nil
        }
        /// The title, or one derived from the legacy reason while the feed still carries the task id.
        public var displayTitle: String { title == id ? (legacy?.title ?? title) : title }
        /// The feed's headed summary, else the legacy reason split into sections.
        public var displayParts: [SummaryPart] { summaryParts.isEmpty ? (legacy?.parts ?? []) : summaryParts }
        public var contextText: String { CompanionFeed.text(fullContext) ?? whyNow }
        public var created: Date? { CompanionFeed.day(createdAt) }
        public func ageDays(now: Date = Date()) -> Int? {
            created.map { max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0), to: Calendar.current.startOfDay(for: now)).day ?? 0) }
        }
    }
    public struct SummaryPart: Decodable, Equatable, Sendable {
        public let heading: String?, text: String
        public init(heading: String?, text: String) { self.heading = heading; self.text = text }
    }
    /// The colleague comment a draft answers (`drafts[].reply_to`); optional.
    public struct ReplyTo: Decodable, Equatable, Sendable { public let author: String?, text: String, at: String?, location: String? }
    public struct Draft: Decodable, Equatable, Sendable, Identifiable {
        public let id: String, targetUrl: String, text: String; public let replyTo: ReplyTo?
        /// Optional review-comment context: where it goes (file:line or a general note), the finding it answers, and
        /// "required" or "non-blocking" when the review says so.
        public let target: String?, placement: String?, finding: String?, severity: String?
        /// The worker task whose report these drafts came from (optional); the Workers tab keeps such a worker out of Sweep.
        public let source: String?
    }
    public struct Action: Decodable, Equatable, Sendable, Identifiable { public let id: String, label: String; public let outward: Bool }
    public struct MergeRequest: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { ref }
        public let ref: String, title: String, role: String, verdict: String, label: String, nextOwner: String
        public let url: URL
        /// The schema allows null for both: the producer could not read them.
        public let pipeline: String?
        public let openThreads: Int?
        public let decisionId: String?
        /// Optional context from the producer; empty strings count as absent.
        public let author: String?, headline: String?, blocker: String?, next: String?, ticket: String?, updatedAt: String?
        /// Optional Linear issue link for `ticket` (https only).
        public let ticketUrl: String?
        /// Time-to-close position (1 = closest to done) and the step it stands for; the producer sorts by it.
        public let closeRank: Int?, closeStep: String?
        /// Optional GitLab state: "opened", "merged" or "closed". A merged or closed MR is not shown.
        public let state: String?
        public var isFinished: Bool { ["merged", "closed"].contains(state?.lowercased() ?? "") }
        /// Live GitLab approvals (optional): who approved, whether the user did and at the current head.
        public let approval: Approval?
        /// The author's username when the user approved at the current head and nothing waits on them: the card sits in "Waiting on others".
        public let waitingOn: String?
        public let drafts: [Draft]
        public let actions: [Action]
        public var postAction: Action? { CompanionFeed.postAction(of: actions) }
    }
    /// `updated_at` as a date, nil when missing, empty or unparseable.
    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        for options in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
    /// A `YYYY-MM-DD` day (a full ISO time is accepted too), nil when missing or unreadable.
    public static func day(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.count >= 10 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
    public static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    /// Marks MR rows whose action posts the draft; nil when the feed offers none.
    public static func postAction(of actions: [Action]) -> Action? { actions.first { $0.id.contains(".post") || $0.id.hasSuffix("-post") } }
    public struct Approval: Decodable, Equatable, Sendable {
        public let approvedBy: [String]?, approvedByMe: Bool?, approvalsLeft: Int?, atHead: Bool?
        /// The MR's head commit when the producer read it; a dismissal lasts until it changes.
        public let headSha: String?
        public init(approvedBy: [String]?, approvedByMe: Bool?, approvalsLeft: Int?, atHead: Bool?, headSha: String? = nil) { self.approvedBy = approvedBy; self.approvedByMe = approvedByMe; self.approvalsLeft = approvalsLeft; self.atHead = atHead; self.headSha = headSha }
        /// Nil when nobody approved. `approvedBy` names the other approvers; the user is `approvedByMe`.
        public var badge: (byMe: Bool, others: [String])? {
            let names = approvedBy ?? []
            guard approvedByMe == true || !names.isEmpty else { return nil }
            return (approvedByMe == true, names)
        }
    }
    public struct Finish: Decodable, Equatable, Sendable { public let step: String, owner: String }
    public struct Ticket: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { identifier }
        public let identifier: String, title: String, status: String
        public let url: URL
        public let finish: Finish?
        public let decisionId: String?
        public let linkedMrs: [String]
        public let actions: [Action]
        /// Optional structured Linear context (`tickets[].detail`); a malformed block is ignored, never a reason to drop the ticket.
        public let detail: TicketDetail?
        private enum Keys: String, CodingKey { case identifier, title, status, url, finish, decisionId, linkedMrs, actions, detail }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            identifier = try c.decode(String.self, forKey: .identifier); title = try c.decode(String.self, forKey: .title); status = try c.decode(String.self, forKey: .status)
            url = try c.decode(URL.self, forKey: .url); finish = try c.decodeIfPresent(Finish.self, forKey: .finish)
            decisionId = try c.decodeIfPresent(String.self, forKey: .decisionId); linkedMrs = try c.decode([String].self, forKey: .linkedMrs)
            actions = try c.decode([Action].self, forKey: .actions); detail = try? c.decodeIfPresent(TicketDetail.self, forKey: .detail)
        }
    }
    public struct AcceptanceItem: Decodable, Equatable, Sendable { public let text: String; public let done: Bool? }
    public struct LinkedMR: Decodable, Equatable, Sendable { public let ref: String; public let url: String?; public let state: String?
        public init(ref: String, url: String?, state: String?) { self.ref = ref; self.url = url; self.state = state } }
    public struct TicketComment: Decodable, Equatable, Sendable { public let author: String?, at: String?, text: String }
    /// Everything the Details box shows beyond status, finish step and owner; every field is optional and never invented.
    public struct TicketDetail: Decodable, Equatable, Sendable {
        public let assignee: String?, priority: String?, summary: String?
        public let labels: [String]?
        public let acceptance: [AcceptanceItem]?
        public let mrs: [LinkedMR]?
        public let comments: [TicketComment]?
        /// Names of the fields the feed did not send, so the box can say what is missing.
        public var missing: [String] {
            var out: [String] = []
            if CompanionFeed.text(assignee) == nil { out.append("assignee") }
            if CompanionFeed.text(priority) == nil { out.append("priority") }
            if (labels ?? []).isEmpty { out.append("labels") }
            if CompanionFeed.text(summary) == nil { out.append("summary") }
            if (acceptance ?? []).isEmpty { out.append("acceptance") }
            if (mrs ?? []).isEmpty { out.append("mrs") }
            if (comments ?? []).isEmpty { out.append("comments") }
            return out
        }
    }

    public let schema: String
    public let generatedAt: Date
    public let producer: String
    public let decisions: [Decision]
    public let mrs: [MergeRequest]
    public let tickets: [Ticket]
    /// The producer's own `warnings` plus one line per row skipped here.
    public let warnings: [String]
    public let skipped: [String]

    private enum CodingKeys: String, CodingKey { case schema, generatedAt, producer, decisions, mrs, tickets, warnings }
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?, problem: String?
        init(from decoder: Decoder) throws {
            do { value = try T(from: decoder); problem = nil }
            catch { value = nil; problem = CompanionFeed.describe(error) }
        }
    }
    /// One bad row is skipped with a warning; schema, producer, generated_at and the three lists stay mandatory.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw CompanionError.unsupportedSchema(schema) }
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        producer = try values.decode(String.self, forKey: .producer)
        var notes: [String] = []
        func rows<T: Decodable>(_ key: CodingKeys, _ type: T.Type) throws -> [T?] {
            let list = try values.decode([Lossy<T>].self, forKey: key)
            for (index, row) in list.enumerated() { if let problem = row.problem { notes.append("\(key.stringValue)[\(index)]: \(problem)") } }
            return list.map(\.value)
        }
        let decisionRows = try rows(CodingKeys.decisions, Decision.self), mrRows = try rows(CodingKeys.mrs, MergeRequest.self), ticketRows = try rows(CodingKeys.tickets, Ticket.self)
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
        var seen = Set<String>()
        func keep<T>(_ list: [T?], _ name: String, id: (T) -> String, check: (T) throws -> Void) -> [T] {
            var kept: [T] = []
            for (index, row) in list.enumerated() {
                guard let row else { continue }
                do {
                    try check(row)
                    guard seen.insert(name + ":" + id(row)).inserted else { throw CompanionError.invalid("duplicate \(id(row))") }
                    kept.append(row)
                } catch { notes.append("\(name)[\(index)]: \(Self.describe(error))") }
            }
            return kept
        }
        decisions = keep(decisionRows, "decisions", id: \.id, check: Self.check)
        mrs = keep(mrRows, "mrs", id: \.ref, check: Self.check)
        tickets = keep(ticketRows, "tickets", id: \.identifier, check: Self.check)
        skipped = notes
    }

    static func describe(_ error: Error) -> String {
        if case CompanionError.invalid(let detail) = error { return detail }
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, _): return "missing field \(key.stringValue)"
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context):
            let field = context.codingPath.map(\.stringValue).filter { Int($0) == nil }.joined(separator: ".")
            return "invalid value in " + (field.isEmpty ? "row" : field)
        @unknown default: return "invalid row"
        }
    }

    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(generatedAt)) }
    public func isStale(now: Date = Date()) -> Bool { age(now: now) > Self.staleAfter }

    /// Top-level decode failures throw. Invalid rows are reported in `skipped` so valid rows remain usable.
    public static func decode(_ data: Data) throws -> CompanionFeed {
        let decoder = Self.jsonDecoder()
        let feed: CompanionFeed
        do { feed = try decoder.decode(CompanionFeed.self, from: data) }
        catch let error as CompanionError { throw error }
        catch { throw CompanionError.invalid(String(describing: error)) }
        return feed
    }

    /// Snake-case keys and ISO 8601 dates, shared by the feed and the dossiers.
    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for options in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = options
                if let date = formatter.date(from: text) { return date }
            }
            throw CompanionError.invalid("invalid date: \(text)")
        }
        return decoder
    }

    private static func need(_ value: String, _ name: String) throws { if value.trimmingCharacters(in: .whitespaces).isEmpty { throw CompanionError.invalid("\(name) missing") } }
    private static func secure(_ url: URL, _ name: String) throws { if url.scheme != "https" { throw CompanionError.invalid("\(name) is not https") } }
    static func check(_ decision: Decision) throws {
        try need(decision.id, "id"); try need(decision.title, "title")
        guard !decision.options.isEmpty else { throw CompanionError.invalid("no options") }
        for option in decision.options { try need(option.label, "options.label") }
        // Decision links may also point at a local page on this Mac (http on loopback).
        for link in decision.links where !(link.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(link.host ?? "")) { try secure(link, "link") }
    }
    static func check(_ mr: MergeRequest) throws {
        try need(mr.ref, "ref"); try secure(mr.url, "url")
        guard verdicts.contains(mr.verdict) else { throw CompanionError.invalid("unknown verdict \(mr.verdict)") }
        guard roles.contains(mr.role) else { throw CompanionError.invalid("unknown role \(mr.role)") }
        for action in mr.actions { try need(action.id, "actions.id") }
        for draft in mr.drafts { try need(draft.id, "drafts.id"); try need(draft.text, "drafts.text") }
    }
    static func check(_ ticket: Ticket) throws {
        try need(ticket.identifier, "identifier"); try secure(ticket.url, "url")
        for action in ticket.actions { try need(action.id, "actions.id") }
    }

    public static func read(path: String) throws -> CompanionFeed {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { throw CompanionError.missingFile }
        return try decode(data)
    }
    public static let defaultPath = "~/Library/Application Support/ModelDeck/companion/feed.json"
}

public enum CompanionError: LocalizedError, Equatable {
    case missingFile, unsupportedSchema(String), invalid(String), noInbox, unsafeInbox
    public var errorDescription: String? {
        switch self {
        case .missingFile: "Feed non trovato."
        case .unsupportedSchema(let value): "Schema non supportato: \(value)"
        case .invalid(let detail): "Feed non valido: \(detail)"
        case .noInbox: "Imposta la cartella inbox per inviare azioni."
        case .unsafeInbox: "La cartella inbox non è utilizzabile."
        }
    }
}

/// How pressing a decision is; the raw order is the sort order (urgent first).
public enum DecisionPriority: Int, Comparable, Sendable {
    case urgent = 0, high = 1, normal = 2
    public static func < (a: DecisionPriority, b: DecisionPriority) -> Bool { a.rawValue < b.rawValue }
}
