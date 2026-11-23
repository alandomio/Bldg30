import Foundation

// The Fleet view reads `workers.json` (schema companion-workers.v1), written by the feed producer.
// Pure and read-only: no firstmate call, no state of its own. Drawing is `FleetView`.

/// One worker state as the producer names it. An unknown string decodes as `.unknown`.
public enum FleetState: String, CaseIterable, Sendable {
    case working, waitingDecision = "waiting on a decision", waitingPrompt = "waiting on a prompt", paused, blocked, failed
    case done, idle, stopped, dead, unknown

    public init(raw: String?) { self = raw.flatMap(FleetState.init(rawValue:)) ?? .unknown }

    /// Sort group: needs somebody first, then working, then paused, then the rest.
    public var rank: Int {
        switch self {
        case .waitingDecision, .waitingPrompt, .blocked, .failed: 0
        case .working: 1
        case .paused: 2
        default: 3
        }
    }
    public var needsAttention: Bool { rank == 0 }
    public var isFinished: Bool { self == .done || self == .stopped }
}

public struct FleetWorker: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let project: String
    public let kind: String
    public let harness: String
    public let model: String
    public let state: FleetState
    public let crewState: String
    public let detail: String
    public let waitingOn: String
    public let lastActivityAt: Date?
    public let ageSeconds: Double?
    public let links: [String]

    enum Keys: String, CodingKey { case id, name, project, kind, harness, model, state, crewState = "crew_state", detail, waitingOn = "waiting_on", lastActivityAt = "last_activity_at", ageSeconds = "age_seconds", links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        let id = text(.id), name = text(.name)
        self.id = id.isEmpty ? name : id
        self.name = name.isEmpty ? id : name
        project = text(.project); kind = text(.kind); harness = text(.harness); model = text(.model)
        state = FleetState(raw: ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil))
        crewState = text(.crewState); detail = text(.detail); waitingOn = text(.waitingOn)
        lastActivityAt = CompanionFeed.date((try? c.decodeIfPresent(String.self, forKey: .lastActivityAt)) ?? nil)
        ageSeconds = (try? c.decodeIfPresent(Double.self, forKey: .ageSeconds)) ?? nil
        links = ((try? c.decodeIfPresent([String].self, forKey: .links)) ?? nil) ?? []
    }

    /// Seconds since the last activity; from the timestamp when there is one, else the producer's age.
    public func age(now: Date = Date()) -> TimeInterval? {
        if let lastActivityAt { return max(0, now.timeIntervalSince(lastActivityAt)) }
        return ageSeconds
    }
    /// Harness and model, with a dash when the home does not report them (remote homes).
    public var engine: String {
        let parts = [harness, model].filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

public struct FleetHome: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let machine: String
    public let home: String
    public let remote: Bool
    public let ok: Bool
    public let error: String?
    public let observedAt: Date?
    public let summaryAt: Date?
    public let omitted: Int
    public let workers: [FleetWorker]
    public var id: String { machine + "/" + name }

    enum Keys: String, CodingKey { case name, machine, home, remote, ok, error, observedAt = "observed_at", summaryAt = "summary_at", omitted, workers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "?"
        machine = ((try? c.decodeIfPresent(String.self, forKey: .machine)) ?? nil) ?? "?"
        home = ((try? c.decodeIfPresent(String.self, forKey: .home)) ?? nil) ?? ""
        remote = ((try? c.decodeIfPresent(Bool.self, forKey: .remote)) ?? nil) ?? false
        // A home that does not say it is fine is not trusted: unreachable until proven.
        ok = ((try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil) ?? false
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
        observedAt = CompanionFeed.date((try? c.decodeIfPresent(String.self, forKey: .observedAt)) ?? nil)
        summaryAt = CompanionFeed.date((try? c.decodeIfPresent(String.self, forKey: .summaryAt)) ?? nil)
        omitted = ((try? c.decodeIfPresent(Int.self, forKey: .omitted)) ?? nil) ?? 0
        workers = ((try? c.decodeIfPresent([FleetWorker].self, forKey: .workers)) ?? nil) ?? []
    }

    /// Worker count per state, in display order, states with no worker left out.
    public var counts: [(state: FleetState, count: Int)] {
        FleetState.allCases.compactMap { state in
            let n = workers.filter { $0.state == state }.count
            return n > 0 ? (state, n) : nil
        }
    }
}

public struct FleetSnapshot: Decodable, Equatable, Sendable {
    public static let schema = "companion-workers.v1"
    /// Older than this, the file counts as outdated (the producer writes about every 15 minutes).
    public static let staleAfter: TimeInterval = 30 * 60
    /// Finished workers older than this are hidden unless "show finished" is on.
    public static let finishedHideAfter: TimeInterval = 24 * 3600
    public static let defaultPath = "~/Library/Application Support/ModelDeck/companion/workers.json"

    public let schema: String
    public let generatedAt: Date
    public let homes: [FleetHome]

    enum Keys: String, CodingKey { case schema, generatedAt = "generated_at", homes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schema = try c.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw CompanionError.unsupportedSchema(schema) }
        guard let generated = CompanionFeed.date(try c.decode(String.self, forKey: .generatedAt)) else { throw CompanionError.invalid("generated_at") }
        generatedAt = generated
        homes = try c.decode([FleetHome].self, forKey: .homes)
    }

    public static func decode(_ data: Data) throws -> FleetSnapshot {
        do { return try JSONDecoder().decode(FleetSnapshot.self, from: data) }
        catch let error as CompanionError { throw error }
        catch { throw CompanionError.invalid(error.localizedDescription) }
    }
    public static func read(path: String) throws -> FleetSnapshot {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { throw CompanionError.missingFile }
        return try decode(data)
    }

    public func age(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(generatedAt)) }
    public func isStale(now: Date = Date()) -> Bool { age(now: now) > Self.staleAfter }

    /// Homes grouped by machine (machines in order of first appearance), homes in file order inside a machine.
    public var machines: [(machine: String, homes: [FleetHome])] {
        var order: [String] = []
        for home in homes where !order.contains(home.machine) { order.append(home.machine) }
        return order.map { machine in (machine, homes.filter { $0.machine == machine }) }
    }

    /// The rows to show for one home, sorted; finished workers older than 24 h are left out unless `showFinished`.
    public static func rows(_ workers: [FleetWorker], showFinished: Bool, now: Date = Date()) -> [FleetWorker] {
        let shown = showFinished ? workers : workers.filter { !($0.state.isFinished && ($0.age(now: now) ?? 0) > finishedHideAfter) }
        return shown.enumerated().sorted { a, b in
            if a.element.state.rank != b.element.state.rank { return a.element.state.rank < b.element.state.rank }
            let x = a.element.age(now: now) ?? -1, y = b.element.age(now: now) ?? -1
            return x != y ? x > y : a.offset < b.offset   // oldest first; unknown age last
        }.map(\.element)
    }
}

/// A link as a short label plus where it opens: https in the browser, a file path in Finder.
public enum FleetLink: Equatable, Sendable {
    case web(URL, label: String)
    case file(URL, label: String)

    public static func make(_ raw: String) -> FleetLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("https://"), let url = URL(string: text), url.host != nil {
            if let range = text.range(of: #"/-/merge_requests/(\d+)"#, options: .regularExpression) {
                return .web(url, label: "MR !" + text[range].split(separator: "/").last!)
            }
            if let range = text.range(of: #"/issue/([A-Z]+-\d+)"#, options: .regularExpression) {
                return .web(url, label: String(text[range].split(separator: "/").last!))
            }
            return .web(url, label: url.host ?? text)
        }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            return .file(URL(fileURLWithPath: path), label: (path as NSString).lastPathComponent)
        }
        return nil
    }
}
