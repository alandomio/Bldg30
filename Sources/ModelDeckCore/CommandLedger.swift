import Foundation

/// Lifecycle of one command (a click): queued, then picked_up, then done or failed. Forward only.
public enum CommandState: String, Sendable, CaseIterable {
    case queued, pickedUp = "picked_up", done, failed
    var rank: Int { switch self { case .queued: 0; case .pickedUp: 1; case .done, .failed: 2 } }
    public var isTerminal: Bool { rank == 2 }
    /// A transition is accepted only when it moves forward and the command is not finished.
    public func accepts(_ next: CommandState) -> Bool { !isTerminal && next.rank > rank }
}

/// One line of `commands.jsonl`: `{id, action_id, target, state, at, note}`; `label` is an optional extra on the queued line.
public struct CommandRecord: Codable, Equatable, Sendable {
    public let id: String, actionID: String, target: String, state: String, at: String
    public let note: String?, label: String?
    private enum CodingKeys: String, CodingKey { case id, actionID = "action_id", target, state, at, note, label }
    public init(id: String, actionID: String, target: String, state: CommandState, at: Date = Date(), note: String? = nil, label: String? = nil) {
        self.id = id; self.actionID = actionID; self.target = target; self.state = state.rawValue
        self.at = CommandLedger.format(at); self.note = note; self.label = label
    }
}

public struct Command: Equatable, Sendable, Identifiable {
    public let id: String, actionID: String, target: String
    public var label: String?
    public var state: CommandState
    public var queuedAt: Date?, pickedUpAt: Date?, finishedAt: Date?
    public var note: String?
}

/// The commands of `commands.jsonl`, folded line by line. State is only what a line says; time never changes it.
public struct CommandLedger: Equatable, Sendable {
    /// In the order their queued lines appeared (oldest first).
    public private(set) var commands: [Command] = []
    /// Lines that were not used: unreadable, unknown state, unknown id, backwards or repeated transitions.
    public private(set) var ignoredLines = 0
    private var index: [String: Int] = [:]

    public init(lines: [String] = []) { for line in lines { apply(line: line) } }
    public init(text: String) { self.init(lines: text.split(whereSeparator: \.isNewline).map(String.init)) }

    public mutating func apply(line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let data = text.data(using: .utf8), let record = try? JSONDecoder().decode(CommandRecord.self, from: data),
              let state = CommandState(rawValue: record.state), !record.id.isEmpty else { ignoredLines += 1; return }
        let date = Self.parse(record.at)
        let note = CompanionFeed.text(record.note)
        if let position = index[record.id] {
            guard commands[position].state.accepts(state) else { ignoredLines += 1; return }
            commands[position].state = state
            if state == .pickedUp { commands[position].pickedUpAt = date } else { commands[position].finishedAt = date }
            if let note { commands[position].note = note }
        } else if state == .queued {
            index[record.id] = commands.count
            commands.append(Command(id: record.id, actionID: record.actionID, target: record.target, label: CompanionFeed.text(record.label), state: .queued, queuedAt: date, note: note))
        } else { ignoredLines += 1 }   // a transition for an id that was never queued
    }

    public func command(id: String) -> Command? { index[id].map { commands[$0] } }
    /// The newest command for a card (target), optionally for one action.
    public func latest(target: String, actionID: String? = nil) -> Command? { commands.last { $0.target == target && (actionID == nil || $0.actionID == actionID) } }
    /// Newest first, optionally only one card.
    public func history(target: String? = nil) -> [Command] { commands.reversed().filter { target == nil || $0.target == target } }
    /// Cards that have commands, newest activity first.
    public var targets: [String] {
        var seen = Set<String>(); return commands.reversed().compactMap { seen.insert($0.target).inserted ? $0.target : nil }
    }

    static func parse(_ text: String) -> Date? { CompanionFeed.date(text) }
    static func format(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
}

/// Appends records to `commands.jsonl`. One `write` on an O_APPEND descriptor keeps lines whole next to another writer.
public enum CommandLog {
    /// `commands.jsonl` beside the inbox folder (companion/commands.jsonl for the real inbox).
    public static func url(inbox: String) -> URL {
        URL(fileURLWithPath: (inbox.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath).deletingLastPathComponent().appendingPathComponent("commands.jsonl")
    }
    public static func append(_ record: CommandRecord, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record); data.append(0x0A)
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
    /// The last megabyte of the file as lines (a cut first line is dropped); empty when the file is missing.
    public static func read(_ file: URL, maxBytes: Int = 1_000_000) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8) else { return [] }
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// What a card shows about its commands: one status line, which buttons may run now, and a plain-language history.
public enum CardActivity {
    /// Actions that can run beside another one: asking "Wait, what?" and adding context change nothing.
    public static func isParallelSafe(actionID: String) -> Bool { actionID.hasSuffix(".wait-what") || actionID.hasSuffix(".add-context") }

    /// The newest command of the card that is sent but not finished (Sent or picked up), if any.
    public static func inFlight(target: String, ledger: CommandLedger) -> Command? {
        ledger.commands.last { $0.target == target && ($0.state == .queued || $0.state == .pickedUp) && !isParallelSafe(actionID: $0.actionID) }
    }
    /// A button may run when nothing else is in flight on its card, or when it is parallel-safe.
    public static func canRun(actionID: String, target: String, ledger: CommandLedger) -> Bool {
        isParallelSafe(actionID: actionID) || inFlight(target: target, ledger: ledger) == nil
    }

    /// One short sentence about the card's newest command: Sent, Firstmate is on it, Done, Failed: reason.
    public static func statusText(_ command: Command, language: DeckLanguage = .current) -> String {
        func t(_ key: String) -> String { DeckLocalization.dynamic(key, language: language) }
        switch command.state {
        case .queued: return t("Inviato")
        case .pickedUp: return t("Firstmate se ne sta occupando")
        case .done: return t("Fatto")
        case .failed: return command.note.map { t("Fallito") + ": " + String($0.prefix(160)) } ?? t("Fallito")
        }
    }
    /// The button text the person pressed, or the action id turned into words.
    public static func plainLabel(_ command: Command) -> String {
        if let label = command.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        let tail = command.actionID.split(separator: ".").last.map(String.init) ?? command.actionID
        switch tail {
        case "opt-defer": return "Defer one week"
        case "opt-drop": return "Drop it"
        case "add-context": return "Add context"
        case "wait-what": return "Wait, what?"
        case "nevermind": return "Nevermind"
        case "free-text", "answer": return "Free answer"
        default:
            let words = tail.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
    /// The card's commands, newest first.
    public static func history(target: String, ledger: CommandLedger) -> [Command] { ledger.history(target: target) }
}


/// Review comment drafts on an MR card: each draft has its own post action (`<row>.comment-<draft id>`), so each is posted,
/// edited or discarded on its own and "Post all" is one confirmed click per draft.
public enum ReviewDrafts {
    public static let marker = ".comment-"
    public static func actionID(for draft: CompanionFeed.Draft, in actions: [CompanionFeed.Action]) -> String? {
        actions.first { $0.id.hasSuffix(marker + draft.id) }?.id
    }
    /// True when every draft has its own post action; otherwise the card keeps the one-draft-at-a-time panel.
    public static func isPerDraft(_ drafts: [CompanionFeed.Draft], actions: [CompanionFeed.Action]) -> Bool {
        !drafts.isEmpty && drafts.allSatisfy { actionID(for: $0, in: actions) != nil }
    }
    /// Actions shown as buttons: the per-draft post actions sit on their drafts, not in the button row.
    public static func buttons(_ actions: [CompanionFeed.Action]) -> [CompanionFeed.Action] { actions.filter { !$0.id.contains(marker) } }
    public static func label(_ severity: String?) -> String? {
        switch severity?.lowercased() { case "required": "Required"; case "non-blocking", "nonblocking": "Non-blocking"; default: nil }
    }
    public static func isPosted(_ draft: CompanionFeed.Draft, target: String, actions: [CompanionFeed.Action], ledger: CommandLedger) -> Bool {
        actionID(for: draft, in: actions).map { ledger.latest(target: target, actionID: $0)?.state == .done } ?? false
    }
    /// Names one discarded draft across launches: card, draft id and a fixed hash of the text, so a rewritten draft comes back.
    public static func discardKey(target: String, draft: CompanionFeed.Draft) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in draft.text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return target + "|" + draft.id + "|" + String(hash, radix: 16)
    }
    /// Drafts still to decide: not posted and not discarded (`discarded` holds discard keys).
    public static func remaining(_ drafts: [CompanionFeed.Draft], target: String, actions: [CompanionFeed.Action], ledger: CommandLedger, discarded: Set<String>) -> [CompanionFeed.Draft] {
        drafts.filter { !discarded.contains(discardKey(target: target, draft: $0)) && !isPosted($0, target: target, actions: actions, ledger: ledger) }
    }
}
