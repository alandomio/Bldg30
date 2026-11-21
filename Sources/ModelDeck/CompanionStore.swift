import Foundation
@preconcurrency import UserNotifications
import ModelDeckCore

enum CompanionSettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "companionEnabled") }
    static var feedPath: String { CommandArguments.value(after: "--feed") ?? UserDefaults.standard.string(forKey: "companionFeedPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionFeed.defaultPath }
    static var inboxPath: String { CommandArguments.value(after: "--inbox") ?? UserDefaults.standard.string(forKey: "companionInboxPath") ?? "" }
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
        refreshCommands()
    }

    /// Reads `commands.jsonl` beside the inbox for card status and per-card history.
    func refreshCommands() {
        let ledger = CommandLedger(lines: CommandLog.read(CommandLog.url(inbox: CompanionSettings.inboxPath)))
        if ledger != commandLedger { commandLedger = ledger }
    }

    /// Refreshes card status even on failure so the ledger can show the result of the send.
    @discardableResult
    func sendCompanionClick(actionID: String, target: String, draftText: String? = nil, label: String? = nil) -> String? {
        if demo { return nil }
        let click = CompanionClick(actionID: actionID, target: target, draftText: draftText)
        let error = ClickSender.send(click, label: label, inbox: CompanionSettings.inboxPath)
        refreshCommands()
        return error
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
