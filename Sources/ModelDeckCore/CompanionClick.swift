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

public enum CompanionClickStatus: String, Sendable { case sent, queued, pickedUp, done, rejected, waiting }

/// Firstmate's receipt for a click, from `replies/<idempotency_key>.json` (companion-reply.v1) beside the feed.
public struct CompanionReceipt: Equatable, Sendable {
    public let status: CompanionClickStatus
    public let text: String?
    /// Without any receipt after this long the app says firstmate may not be monitoring.
    public static let waitAfter: TimeInterval = 120

    public static func repliesDirectory(feedPath: String) -> URL {
        URL(fileURLWithPath: (feedPath as NSString).expandingTildeInPath).deletingLastPathComponent().appendingPathComponent("replies", isDirectory: true)
    }

    public static func resolve(note: URL, key: String, repliesDirectory: URL, sentAt: Date, now: Date = Date()) -> CompanionReceipt {
        if let data = FileManager.default.contents(atPath: repliesDirectory.appendingPathComponent(key + ".json").path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["schema"] as? String == "companion-reply.v1" {
            let text = (object["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch object["status"] as? String {
            case "queued": return CompanionReceipt(status: .queued, text: text)
            case "picked_up": return CompanionReceipt(status: .pickedUp, text: text)
            case "done": return CompanionReceipt(status: .done, text: text)
            case "rejected": return CompanionReceipt(status: .rejected, text: text)
            default: break
            }
        }
        let inferred = CompanionInbox.status(of: note)
        if inferred == .sent, now.timeIntervalSince(sentAt) > waitAfter { return CompanionReceipt(status: .waiting, text: nil) }
        return CompanionReceipt(status: inferred, text: nil)
    }
}

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

    /// A draft's post button: the MR row's own post action from the feed, the MR ref as target, the shown (possibly edited) text.
    public static func postClick(mr: CompanionFeed.MergeRequest, text: String, now: Date = Date(), key: String = UUID().uuidString.lowercased()) -> CompanionClick? {
        guard let action = mr.postAction, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CompanionClick(actionID: action.id, target: mr.ref, draftText: text, now: now, key: key)
    }
    /// A row action button: the feed's action id and the row ref.
    public static func rowClick(action: CompanionFeed.Action, ref: String, draftText: String? = nil, now: Date = Date(), key: String = UUID().uuidString.lowercased()) -> CompanionClick {
        CompanionClick(actionID: action.id, target: ref, draftText: draftText, now: now, key: key)
    }
}

/// Picks the action to highlight on a row: the one the feed's text names, else the first harmless one.
public enum CompanionRecommendation {
    static let quiet = [".wait-what", ".nevermind"]
    public static func actionID(in actions: [CompanionFeed.Action], texts: [String?]) -> String? {
        let words = Set(texts.compactMap { $0 }.joined(separator: " ").lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
        func score(_ action: CompanionFeed.Action) -> Int { Set(action.label.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }).intersection(words).count }
        let candidates = actions.filter { action in !action.outward && !quiet.contains { action.id.hasSuffix($0) } }
        if let best = candidates.max(by: { score($0) < score($1) }), score(best) > 0 { return best.id }
        return candidates.first?.id
    }
    /// The recommended action first, the others in feed order.
    public static func ordered(_ actions: [CompanionFeed.Action], recommended: String?) -> [CompanionFeed.Action] {
        guard let recommended, let index = actions.firstIndex(where: { $0.id == recommended }) else { return actions }
        var result = actions; result.insert(result.remove(at: index), at: 0); return result
    }
}
