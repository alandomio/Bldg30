import Foundation
@preconcurrency import UserNotifications
import ModelDeckCore

enum CompanionSettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "companionEnabled") }
    static var feedPath: String { CommandLine.arguments.firstIndex(of: "--feed").map { CommandLine.arguments[$0 + 1] } ?? UserDefaults.standard.string(forKey: "companionFeedPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionFeed.defaultPath }
    static var inboxPath: String { UserDefaults.standard.string(forKey: "companionInboxPath") ?? "" }
}

extension DeckStore {
    /// Reads the feed file. A bad or missing file keeps the last good feed visible with its age and shows the error.
    func refreshCompanion() {
        guard !demo else { return }
        guard CompanionSettings.enabled else { companionFeed = nil; companionError = nil; return }
        do {
            let feed = try CompanionFeed.read(path: CompanionSettings.feedPath)
            if feed != companionFeed { companionFeed = feed }
            companionError = nil
            announceUrgent(feed)
        } catch { companionError = error.localizedDescription }
        let replies = CompanionReceipt.repliesDirectory(feedPath: CompanionSettings.feedPath)
        for (key, sent) in companionNotes {
            let receipt = CompanionReceipt.resolve(note: sent.note, key: sent.key, repliesDirectory: replies, sentAt: sent.at)
            if companionStatuses[key] != receipt.status { companionStatuses[key] = receipt.status }
            if companionReceiptText[key] != receipt.text { companionReceiptText[key] = receipt.text }
        }
    }

    /// Files one click note. Returns an error text, or nil on success.
    @discardableResult
    func sendCompanionClick(actionID: String, target: String, draftText: String? = nil) -> String? {
        if demo { companionStatuses[actionID + "|" + target] = .sent; return nil }
        do {
            let click = CompanionClick(actionID: actionID, target: target, draftText: draftText)
            let note = try CompanionInbox.file(click, inbox: CompanionSettings.inboxPath)
            let key = actionID + "|" + target
            companionNotes[key] = SentClick(note: note, key: click.idempotencyKey, at: Date()); companionStatuses[key] = .sent; companionReceiptText[key] = nil
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
