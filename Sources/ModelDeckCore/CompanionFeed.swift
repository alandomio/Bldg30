import Foundation

/// Reader for `companion-feed.v1`, a JSON file a companion tool writes and the app only renders.
public struct CompanionFeed: Decodable, Equatable, Sendable {
    public static let schema = "companion-feed.v1"
    /// The producer refreshes every 5 minutes; three missed refreshes count as stale.
    public static let staleAfter: TimeInterval = 15 * 60
    public static let verdicts: Set<String> = ["close", "notyet", "blocked", "hold"]
    public static let roles: Set<String> = ["author", "reviewer"]

    public struct Option: Decodable, Equatable, Sendable { public let label: String; public let consequence: String }
    public struct Decision: Decodable, Equatable, Sendable, Identifiable {
        public let id: String, title: String, project: String, whyNow: String, recommendation: String
        public let options: [Option]
        public let links: [URL]
        public let urgent: Bool
    }
    public struct Draft: Decodable, Equatable, Sendable, Identifiable { public let id: String, targetUrl: String, text: String }
    public struct Action: Decodable, Equatable, Sendable, Identifiable { public let id: String, label: String; public let outward: Bool }
    public struct MergeRequest: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { ref }
        public let ref: String, title: String, role: String, verdict: String, label: String, nextOwner: String, pipeline: String
        public let url: URL
        public let openThreads: Int
        public let drafts: [Draft]
        public let actions: [Action]
    }
    public struct Finish: Decodable, Equatable, Sendable { public let step: String, owner: String }
    public struct Ticket: Decodable, Equatable, Sendable, Identifiable {
        public var id: String { identifier }
        public let identifier: String, title: String, status: String
        public let url: URL
        public let finish: Finish?
        public let linkedMrs: [String]
        public let actions: [Action]
    }

    public let schema: String
    public let generatedAt: Date
    public let producer: String
    public let decisions: [Decision]
    public let mrs: [MergeRequest]
    public let tickets: [Ticket]

    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(generatedAt)) }
    public func isStale(now: Date = Date()) -> Bool { age(now: now) > Self.staleAfter }

    /// Decodes and validates. Any malformed or unknown value throws, so a producer bug never reads as "nothing to do".
    public static func decode(_ data: Data) throws -> CompanionFeed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for options in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = options
                if let date = formatter.date(from: text) { return date }
            }
            throw CompanionError.invalid("data non valida: \(text)")
        }
        let feed: CompanionFeed
        do { feed = try decoder.decode(CompanionFeed.self, from: data) }
        catch let error as CompanionError { throw error }
        catch { throw CompanionError.invalid(String(describing: error)) }
        try feed.validate()
        return feed
    }

    func validate() throws {
        guard schema == Self.schema else { throw CompanionError.unsupportedSchema(schema) }
        func need(_ value: String, _ name: String) throws { if value.trimmingCharacters(in: .whitespaces).isEmpty { throw CompanionError.invalid("\(name) mancante") } }
        func secure(_ url: URL, _ name: String) throws { if url.scheme != "https" { throw CompanionError.invalid("\(name) non è https") } }
        try need(producer, "producer")
        var seen = Set<String>()
        for decision in decisions {
            try need(decision.id, "decisions.id"); try need(decision.title, "decisions.title")
            guard seen.insert("d:" + decision.id).inserted else { throw CompanionError.invalid("decision duplicata \(decision.id)") }
            for option in decision.options { try need(option.label, "options.label") }
            for link in decision.links { try secure(link, "link") }
        }
        for mr in mrs {
            try need(mr.ref, "mrs.ref"); try need(mr.title, "mrs.title"); try secure(mr.url, "mrs.url")
            guard Self.verdicts.contains(mr.verdict) else { throw CompanionError.invalid("verdict sconosciuto \(mr.verdict)") }
            guard Self.roles.contains(mr.role) else { throw CompanionError.invalid("role sconosciuto \(mr.role)") }
            guard seen.insert("m:" + mr.ref).inserted else { throw CompanionError.invalid("mr duplicata \(mr.ref)") }
            for action in mr.actions { try need(action.id, "actions.id") }
            for draft in mr.drafts { try need(draft.id, "drafts.id"); try need(draft.text, "drafts.text") }
        }
        for ticket in tickets {
            try need(ticket.identifier, "tickets.identifier"); try need(ticket.title, "tickets.title"); try secure(ticket.url, "tickets.url")
            guard seen.insert("t:" + ticket.identifier).inserted else { throw CompanionError.invalid("ticket duplicato \(ticket.identifier)") }
            for action in ticket.actions { try need(action.id, "actions.id") }
        }
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
