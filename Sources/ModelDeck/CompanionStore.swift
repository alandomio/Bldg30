import Foundation
@preconcurrency import UserNotifications
import ModelDeckCore

enum CompanionSettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "companionEnabled") }
    static var feedPath: String { UserDefaults.standard.string(forKey: "companionFeedPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionFeed.defaultPath }
    static var inboxPath: String { UserDefaults.standard.string(forKey: "companionInboxPath") ?? "" }
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

extension DeckStore {
    /// Reads the feed file. A bad or missing file keeps the last good feed visible with its age and shows the error.
    func refreshCompanion() {
        guard !demo else { return }
        refreshDeckReplies()
        guard CompanionSettings.enabled else { companionFeed = nil; companionError = nil; return }
        do {
            let feed = try CompanionFeed.read(path: CompanionSettings.feedPath)
            if feed != companionFeed { companionFeed = feed }
            companionError = nil
            announceUrgent(feed)
        } catch { companionError = error.localizedDescription }
        for (key, note) in companionNotes {
            let status = CompanionInbox.status(of: note)
            if companionStatuses[key] != status { companionStatuses[key] = status }
        }
    }

    /// Files one click note. Returns an error text, or nil on success.
    @discardableResult
    func sendCompanionClick(actionID: String, target: String, draftText: String? = nil) -> String? {
        if demo { companionStatuses[actionID + "|" + target] = .sent; return nil }
        do {
            let note = try CompanionInbox.file(CompanionClick(actionID: actionID, target: target, draftText: draftText), inbox: CompanionSettings.inboxPath)
            let key = actionID + "|" + target
            companionNotes[key] = note; companionStatuses[key] = .sent
            return nil
        } catch { return error.localizedDescription }
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
