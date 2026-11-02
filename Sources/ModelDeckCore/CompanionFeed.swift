import Foundation

/// Reader for `companion-feed.v1`, a JSON file a companion tool writes and the app only renders.
public struct CompanionFeed: Decodable, Equatable, Sendable {
    public static let schema = "companion-feed.v1"
    /// The producer refreshes every 5 minutes; three missed refreshes count as stale.
    public static let staleAfter: TimeInterval = 15 * 60
    public static let verdicts: Set<String> = ["close", "notyet", "blocked", "hold"]
    public static let roles: Set<String> = ["author", "reviewer"]

    public struct Option: Decodable, Equatable, Sendable { public let label: String; public let consequence: String; public let actionId: String?; public let outward: Bool? }
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
        public let ref: String, title: String, role: String, verdict: String, label: String, nextOwner: String
        public let url: URL
        /// The schema allows null for both: the producer could not read them.
        public let pipeline: String?
        public let openThreads: Int?
        public let decisionId: String?
        public let drafts: [Draft]
        public let actions: [Action]
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

    /// Decodes and validates. Any malformed or unknown value throws, so a producer bug never reads as "nothing to do".
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
