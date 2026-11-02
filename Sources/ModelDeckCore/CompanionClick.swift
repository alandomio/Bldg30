import Foundation

/// `companion-click.v1`: one JSON note per button click, filed into a configurable inbox folder.
public struct CompanionClick: Codable, Equatable, Sendable {
    public static let schema = "companion-click.v1"
    public let schemaName: String
    public let idempotencyKey: String
    public let actionID: String
    public let target: String
    public let draftText: String?
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case schemaName = "schema", idempotencyKey = "idempotency_key", actionID = "action_id", target, draftText = "draft_text", createdAt = "created_at"
    }

    public init(actionID: String, target: String, draftText: String? = nil, now: Date = Date(), key: String = UUID().uuidString.lowercased()) {
        schemaName = Self.schema; idempotencyKey = key; self.actionID = actionID; self.target = target; self.draftText = draftText
        createdAt = ISO8601DateFormatter().string(from: now)
    }
}

public enum CompanionClickStatus: String, Sendable { case sent, pickedUp, done }

public enum CompanionInbox {
    /// Writes the note atomically (temp file, then rename) so the reader never sees a half-written file.
    @discardableResult
    public static func file(_ click: CompanionClick, inbox: String, now: Date = Date()) throws -> URL {
        let path = (inbox.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw CompanionError.noInbox }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw CompanionError.unsafeInbox }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(click)
        let name = "\(Int(now.timeIntervalSince1970))-\(click.idempotencyKey)"
        let final = URL(fileURLWithPath: path).appendingPathComponent(name + ".json")
        try data.write(to: final, options: .atomic)
        return final
    }

    /// sent: the note is still in the inbox. pickedUp: it moved to `handled/`. done: a `<name>.reply.json` sits beside it.
    public static func status(of note: URL) -> CompanionClickStatus {
        let manager = FileManager.default
        let base = note.deletingPathExtension().lastPathComponent
        let folder = note.deletingLastPathComponent()
        let handled = folder.appendingPathComponent("handled")
        for place in [folder, handled] where manager.fileExists(atPath: place.appendingPathComponent(base + ".reply.json").path) { return .done }
        if manager.fileExists(atPath: handled.appendingPathComponent(note.lastPathComponent).path) { return .pickedUp }
        return manager.fileExists(atPath: note.path) ? .sent : .pickedUp
    }
}

/// Builds the click for a decision card: a chosen option keeps its action id, text alone goes to `<decision id>.answer`.
public enum CompanionAnswer {
    /// Only trailing whitespace is dropped; nil when there is neither an option nor text.
    public static func click(decisionID: String, option: CompanionFeed.Option? = nil, optionIndex: Int = 0, text: String, now: Date = Date(), key: String = UUID().uuidString.lowercased()) -> CompanionClick? {
        var typed = text
        while let last = typed.last, last.isWhitespace || last.isNewline { typed.removeLast() }
        if let option {
            let action = option.actionId ?? "decision:\(decisionID):option:\(optionIndex)"
            return CompanionClick(actionID: action, target: decisionID, draftText: typed.isEmpty ? option.label : typed, now: now, key: key)
        }
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CompanionClick(actionID: decisionID + ".answer", target: decisionID, draftText: typed, now: now, key: key)
    }
    /// "Add context" on any card: `<ref>.add-context`, target the ref, the typed text with trailing whitespace dropped.
    public static func contextClick(ref: String, text: String, now: Date = Date(), key: String = UUID().uuidString.lowercased()) -> CompanionClick? {
        var typed = text
        while let last = typed.last, last.isWhitespace || last.isNewline { typed.removeLast() }
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CompanionClick(actionID: ref + ".add-context", target: ref, draftText: typed, now: now, key: key)
    }
    public static func actionID(decisionID: String, option: CompanionFeed.Option?, optionIndex: Int) -> String {
        option.map { $0.actionId ?? "decision:\(decisionID):option:\(optionIndex)" } ?? decisionID + ".answer"
    }
}
