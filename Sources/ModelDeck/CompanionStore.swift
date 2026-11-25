import Foundation
@preconcurrency import UserNotifications
import ModelDeckCore

enum CompanionSettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "companionEnabled") }
    static var feedPath: String { CommandArguments.value(after: "--feed") ?? UserDefaults.standard.string(forKey: "companionFeedPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionFeed.defaultPath }
    static var inboxPath: String { CommandArguments.value(after: "--inbox") ?? UserDefaults.standard.string(forKey: "companionInboxPath") ?? "" }
    /// The Settings option makes the comment tool available; the sidebar switch (default on) shows or hides the boxes.
    static var commentsAvailable: Bool { UserDefaults.standard.bool(forKey: "deckCommentsEnabled") }
    static func loadComments() -> [DeckComment] {
        guard let data = UserDefaults.standard.data(forKey: "deckComments") else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DeckComment].self, from: data)) ?? []
    }
    static func saveComments(_ comments: [DeckComment]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(comments.suffix(200))) { UserDefaults.standard.set(data, forKey: "deckComments") }
    }
}

extension CompanionSettings {
    /// `workers.json` sits beside the feed file; `--workers-file` overrides it for tests.
    static var fleetPath: String {
        if let path = CommandArguments.value(after: "--workers-file") { return path }
        return URL(fileURLWithPath: (feedPath as NSString).expandingTildeInPath).deletingLastPathComponent().appendingPathComponent("workers.json").path
    }
}

extension DeckStore {
    /// Re-reads workers.json only when its modification time changed. A bad file keeps the last good snapshot and shows the error.
    func refreshFleet() {
        guard !demo else { return }
        let path = CompanionSettings.fleetPath
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else {
            fleet = nil; fleetError = nil; fleetModified = nil; return
        }
        guard modified != fleetModified else { return }
        fleetModified = modified
        do { fleet = try FleetSnapshot.read(path: path); fleetError = nil }
        catch { fleetError = error.localizedDescription }
    }
}

extension DeckStore {
    /// Reads the feed file. A bad or missing file keeps the last good feed visible with its age and shows the error.
    func refreshCompanion() {
        guard !demo else { return }
        refreshDeckReplies()
        guard CompanionSettings.enabled else { companionFeed = nil; companionError = nil; companionFeedOutdated = false; return }
        do {
            let feed = try CompanionFeed.read(path: CompanionSettings.feedPath)
            if feed != companionFeed { companionFeed = feed }
            companionError = nil
            announceUrgent(feed)
        } catch { companionError = error.localizedDescription }
        let outdated = companionFeed?.isOutdated() ?? false  // also when the last good feed is all that is left
        if outdated != companionFeedOutdated { companionFeedOutdated = outdated }
        refreshCommands()
    }

    /// Reads `commands.jsonl` beside the inbox for card status and per-card history.
    func refreshCommands() {
        let ledger = CommandLedger(lines: CommandLog.read(CommandLog.url(inbox: CompanionSettings.inboxPath)))
        if ledger != commandLedger { commandLedger = ledger }
    }

    /// Refreshes card status even on failure so the ledger can show the result of the send.
    @discardableResult
    func sendCompanionClick(actionID: String, target: String, draftText: String? = nil, selectedOption: CompanionClick.SelectedOption? = nil, label: String? = nil) -> String? {
        if demo { return nil }
        let click = CompanionClick(actionID: actionID, target: target, draftText: draftText, selectedOption: selectedOption)
        let error = ClickSender.send(click, label: label, inbox: CompanionSettings.inboxPath)
        refreshCommands()
        return error
    }

    func refreshDeckReplies() {
        for comment in deckComments {
            guard let reply = CompanionReply.read(key: comment.key, inbox: CompanionSettings.inboxPath) else { continue }
            if deckReplies[comment.key] != reply { deckReplies[comment.key] = reply }
        }
    }

    /// Files a comment for Deck Officer; target is "global" or the card or row id. Returns an error text, or nil on success.
    @discardableResult
    func sendDeckComment(target: String, text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let click = CompanionClick(actionID: CompanionReply.commentAction, target: target, draftText: body)
        if demo { deckComments.append(DeckComment(key: click.idempotencyKey, target: target, text: body, notePath: "")); return nil }
        do {
            let note = try CompanionInbox.file(click, inbox: CompanionSettings.inboxPath)
            deckComments.append(DeckComment(key: click.idempotencyKey, target: target, text: body, notePath: note.path))
            CompanionSettings.saveComments(deckComments)
            return nil
        } catch { return error.localizedDescription }
    }

    private func announceUrgent(_ feed: CompanionFeed) {
        let defaults = UserDefaults.standard
        var announced = Set(defaults.stringArray(forKey: "companionAnnounced") ?? [])
        let fresh = CompanionNotifications.pending(in: feed, announced: announced)
        guard !fresh.isEmpty, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for decision in fresh {
                let content = UNMutableNotificationContent()
                content.title = D("Decisione urgente"); content.body = decision.title
                center.add(UNNotificationRequest(identifier: "companion-" + decision.id, content: content, trigger: nil))
            }
        }
        announced.formUnion(fresh.map(\.id))
        defaults.set(Array(announced.suffix(500)), forKey: "companionAnnounced")
    }
}
