import Foundation

/// `companion-event.v1`: change events appended as JSON lines, deduplicated by fingerprint, flushed at most once per window.
public struct CompanionEvent: Codable, Equatable, Sendable {
    public static let schema = "companion-event.v1"
    public static let kinds: Set<String> = ["new_comment", "review_requested", "pipeline_changed", "ticket_state", "mr_merged"]
    public let schemaName: String, fingerprint: String, kind: String, ref: String, at: String

    private enum CodingKeys: String, CodingKey { case schemaName = "schema", fingerprint, kind, ref, at }

    /// The fingerprint is a stable FNV-1a hash of source, id and state, so an unchanged item never repeats.
    public init(kind: String, ref: String, source: String, state: String, now: Date = Date()) {
        precondition(Self.kinds.contains(kind), "unknown event kind")
        schemaName = Self.schema; self.kind = kind; self.ref = ref
        fingerprint = Self.hash("\(source)|\(ref)|\(state)"); at = ISO8601DateFormatter().string(from: now)
    }
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(value, radix: 16)
    }
}

public struct CompanionEventBatcher: Sendable {
    public static let window: TimeInterval = 300
    public static let cap = 50
    private var pending: [CompanionEvent] = []
    private var queued = Set<String>()
    private var sent = Set<String>()
    private var lastFlush: Date?
    public init() {}

    public mutating func add(_ event: CompanionEvent) {
        guard !sent.contains(event.fingerprint), queued.insert(event.fingerprint).inserted else { return }
        pending.append(event)
    }
    /// Returns the JSON lines to append, or nil when the window has not elapsed or nothing is queued. At most `cap` lines per flush.
    public mutating func flush(now: Date = Date()) -> String? {
        guard !pending.isEmpty, lastFlush.map({ now.timeIntervalSince($0) >= Self.window }) ?? true else { return nil }
        let batch = Array(pending.prefix(Self.cap)); pending.removeFirst(batch.count)
        for event in batch { sent.insert(event.fingerprint); queued.remove(event.fingerprint) }
        lastFlush = now
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return batch.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }.joined(separator: "\n") + "\n"
    }
    public var pendingCount: Int { pending.count }
}

public enum CompanionEventFile {
    public static func append(_ lines: String, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(lines.utf8))
        } else { try Data(lines.utf8).write(to: url, options: .atomic) }
    }
}
