import Foundation

/// `live.json` (companion-live.v1): the newest status events of every firstmate task, newest first.
public struct CompanionLive: Equatable, Sendable {
    public struct Event: Equatable, Sendable, Identifiable {
        public struct ID: Hashable, Sendable {
            fileprivate let task: String, state: String, text: String, key: String?, at: Date
            fileprivate let occurrence: Int
        }
        public let task: String, state: String, text: String, key: String?, at: Date
        fileprivate var occurrence = 0
        public var id: ID { ID(task: task, state: state, text: text, key: key, at: at, occurrence: occurrence) }
    }
    public static let schema = "companion-live.v1"
    /// Past this age the app asks the producer for a fresh file, and never more often than `minRunGap`.
    public static let staleAfter: TimeInterval = 30
    public static let minRunGap: TimeInterval = 15
    public static let defaultScript = "/Users/a.domio/firstmate/data/shipdeck-wire/bin/wire.py"
    public static let defaultHome = "/Users/a.domio/firstmate"
    public let generatedAt: Date
    public let events: [Event]

    public static func path(besideFeed feedPath: String) -> String {
        ((feedPath as NSString).expandingTildeInPath as NSString).deletingLastPathComponent + "/live.json"
    }

    public static func decode(_ data: Data) throws -> CompanionLive {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionError.invalid("live.json is not an object") }
        guard let schema = root["schema"] as? String, schema == Self.schema else { throw CompanionError.unsupportedSchema(root["schema"] as? String ?? "missing") }
        guard let generated = CompanionFeed.date(root["generated_at"] as? String), let rows = root["events"] as? [[String: Any]] else { throw CompanionError.invalid("live.json lacks generated_at or events") }
        var occurrences: [Event.ID: Int] = [:]
        let events: [Event] = rows.compactMap { row in
            guard let task = row["task"] as? String, let state = row["state"] as? String, let text = row["text"] as? String, let at = CompanionFeed.date(row["at"] as? String) else { return nil }
            var event = Event(task: task, state: state, text: text, key: row["key"] as? String, at: at)
            let identity = event.id
            event.occurrence = occurrences[identity, default: 0]
            occurrences[identity, default: 0] += 1
            return event
        }
        return CompanionLive(generatedAt: generated, events: events.sorted { $0.at > $1.at })
    }

    public static func read(path: String) throws -> CompanionLive {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { throw CompanionError.missingFile }
        return try decode(data)
    }

    /// True when the file is older than `staleAfter` (or absent) and the last run was at least `minRunGap` ago.
    public static func shouldRun(generatedAt: Date?, lastRun: Date?, now: Date = Date()) -> Bool {
        if let lastRun, now.timeIntervalSince(lastRun) < minRunGap { return false }
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > staleAfter
    }

    /// Badge group for a state word; unknown words get the neutral group.
    public enum Tone: Equatable, Sendable { case decision, good, active, warning, bad, neutral }
    public static func tone(of state: String) -> Tone {
        switch state {
        case "needs-decision", "pending-reply": .decision
        case "done", "resolved": .good
        case "working": .active
        case "paused", "note": .neutral
        case "blocked": .warning
        case "failed": .bad
        default: .neutral
        }
    }
}
