import Foundation
@preconcurrency import UserNotifications
import ModelDeckCore

enum CompanionSettings {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "companionEnabled") }
    static var feedPath: String { CommandLine.arguments.firstIndex(of: "--feed").map { CommandLine.arguments[$0 + 1] } ?? UserDefaults.standard.string(forKey: "companionFeedPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionFeed.defaultPath }
    static var inboxPath: String { CommandLine.arguments.firstIndex(of: "--inbox").map { CommandLine.arguments[$0 + 1] } ?? UserDefaults.standard.string(forKey: "companionInboxPath") ?? "" }
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

    /// Files one click note. The queued line goes into `commands.jsonl` first, so a pickup line can never come before it.
    /// Returns an error text, or nil on success.
    @discardableResult
    func sendCompanionClick(actionID: String, target: String, draftText: String? = nil, label: String? = nil) -> String? {
        if demo { return nil }
        let click = CompanionClick(actionID: actionID, target: target, draftText: draftText)
        let log = CommandLog.url(inbox: CompanionSettings.inboxPath)
        do { try CommandLog.append(CommandRecord(id: click.idempotencyKey, actionID: actionID, target: target, state: .queued, label: label), to: log) }
        catch { return error.localizedDescription }
        do { try CompanionInbox.file(click, inbox: CompanionSettings.inboxPath) }
        catch {
            try? CommandLog.append(CommandRecord(id: click.idempotencyKey, actionID: actionID, target: target, state: .failed, note: "Inbox write failed: " + error.localizedDescription), to: log)
            refreshCommands()
            return error.localizedDescription
        }
        refreshCommands()
        return nil
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
