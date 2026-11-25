import Foundation

/// `companion-click.v1`: one JSON note per button click, filed into a configurable inbox folder.
public struct CompanionClick: Codable, Equatable, Sendable {
    /// The exact choice shown at click time, independent of any typed context or later feed refresh.
    public struct SelectedOption: Codable, Equatable, Sendable {
        public let label: String, consequence: String
        public let index: Int
    }
    public static let schema = "companion-click.v1"
    public let schemaName: String
    public let idempotencyKey: String
    public let actionID: String
    public let target: String
    public let draftText: String?
    public let selectedOption: SelectedOption?
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case schemaName = "schema", idempotencyKey = "idempotency_key", actionID = "action_id", target, draftText = "draft_text", selectedOption = "selected_option", createdAt = "created_at"
    }

    public init(actionID: String, target: String, draftText: String? = nil, selectedOption: SelectedOption? = nil, now: Date = Date(), key: String = UUID().uuidString.lowercased()) {
        schemaName = Self.schema; idempotencyKey = key; self.actionID = actionID; self.target = target; self.draftText = draftText
        self.selectedOption = selectedOption
        createdAt = ISO8601DateFormatter().string(from: now)
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
}

/// Builds the click for a decision card: a chosen option keeps its action id, text alone goes to `<decision id>.answer`.
public enum CompanionAnswer {
    /// Only trailing whitespace is dropped; nil when there is neither an option nor text.
    public static func click(decisionID: String, option: CompanionFeed.Option? = nil, optionIndex: Int = 0, text: String, now: Date = Date(), key: String = UUID().uuidString.lowercased()) -> CompanionClick? {
        var typed = text
        while let last = typed.last, last.isWhitespace || last.isNewline { typed.removeLast() }
        if let option {
            let action = option.actionId ?? "decision:\(decisionID):option:\(optionIndex)"
            return CompanionClick(actionID: action, target: decisionID, draftText: typed.isEmpty ? nil : typed,
                                  selectedOption: .init(label: option.label, consequence: option.consequence, index: optionIndex), now: now, key: key)
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
    /// Match one declared choice. Invalid numbers, negation and ambiguous prose never seed a selection.
    public static func optionIndex(recommendation: String, options: [CompanionFeed.Option]) -> Int? {
        let text = recommendation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty else { return nil }
        let exact = options.indices.filter { options[$0].label.lowercased().replacingOccurrences(of: "’", with: "'") == text }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        if text.range(of: #"\b(no|not|never|don't|dont|avoid|without|cannot|can't|reject)\b"#, options: .regularExpression) != nil { return nil }
        let numberPattern = try! NSRegularExpression(pattern: #"\boption\s*([+-]?\d+)\b"#)
        let ns = text as NSString
        let numbers = numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if !numbers.isEmpty {
            guard numbers.count == 1, text.range(of: #"\b(or|and)\s*(option\s*)?[+-]?\d+\b"#, options: .regularExpression) == nil, let number = Int(ns.substring(with: numbers[0].range(at: 1))), options.indices.contains(number - 1) else { return nil }
            return number - 1
        }
        if text.range(of: #"\boption\b"#, options: .regularExpression) != nil { return nil }
        func normalized(_ value: String) -> String { value.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }
        let phrase = " " + normalized(text) + " "
        let named = options.indices.filter { index in
            let label = options[index].label
            var aliases = [normalized(label)]
            // A trailing parenthesis is an explanation, as in "Discard the copy (close the worker)".
            if let paren = label.firstIndex(of: "("), label.hasSuffix(")") {
                let short = normalized(String(label[..<paren]))
                if short.split(separator: " ").count >= 2 { aliases.append(short) }
            }
            return aliases.contains { !$0.isEmpty && phrase.contains(" " + $0 + " ") }
        }
        if named.count == 1 { return named[0] }
        return nil
    }
    /// The recommended action first, the others in feed order.
    public static func ordered(_ actions: [CompanionFeed.Action], recommended: String?) -> [CompanionFeed.Action] {
        guard let recommended, let index = actions.firstIndex(where: { $0.id == recommended }) else { return actions }
        var result = actions; result.insert(result.remove(at: index), at: 0); return result
    }
}

/// `companion-reply.v1`: written by the assistant to `replies/<idempotency_key>.json`, a sibling of the inbox folder.
public struct CompanionReply: Decodable, Equatable, Sendable {
    public let idempotencyKey: String, status: String
    public let text: String?
    private enum CodingKeys: String, CodingKey { case idempotencyKey = "idempotency_key", status, text }

    public static let commentAction = "comment_deck_officer"

    public static func read(key: String, inbox: String) -> CompanionReply? {
        guard !key.isEmpty, !key.contains("/") else { return nil }
        let path = (inbox.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("replies/\(key).json")
        guard let data = try? Data(contentsOf: file), let reply = try? JSONDecoder().decode(CompanionReply.self, from: data), reply.idempotencyKey == key else { return nil }
        return reply
    }
}

/// One comment sent to Deck Officer, kept so it shows with its reply after a restart.
public struct DeckComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String, target: String, text: String, sentAt: Date
    public let notePath: String
    public init(key: String, target: String, text: String, sentAt: Date = Date(), notePath: String) {
        self.key = key; self.target = target; self.text = text; self.sentAt = sentAt; self.notePath = notePath
    }
}
