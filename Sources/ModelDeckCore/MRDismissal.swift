import Foundation

/// The banner line and the dismissal rule of an MR card, both read from live facts of the feed row.
public enum MRDismissal {
    /// The green line of a card with approvals, in the interface language. "You" only when the user approved. Nil when nobody approved.
    public static func banner(approval: CompanionFeed.Approval?, waitingOn: String?, language: DeckLanguage = .current) -> String? {
        guard let badge = approval?.badge else { return nil }
        func t(_ value: DeckLocalizedString) -> String { DeckLocalization.text(value, language: language) }
        let others = badge.others.joined(separator: ", ")
        let who = badge.byMe ? (others.isEmpty ? t("Approvata da te") : t("Approvata da te e \(others)")) : t("Approvata da \(others)")
        let left = approval?.approvalsLeft.map { " · " + t("\(String($0)) rimaste") } ?? ""
        let merge = CompanionFeed.text(waitingOn).map { " · " + t("in attesa di \($0) per il merge") } ?? ""
        return who + left + merge
    }

    /// What must stay the same for a dismissal to hold: the head commit, the state, whether something is owed by the user and the open threads.
    /// A new commit, a new comment addressed to the user (the card comes back from Waiting on others) or a merge or close changes it.
    public static func fingerprint(_ mr: BoardMR) -> String {
        [mr.feedRow?.approval?.headSha ?? "", mr.feedRow?.state ?? "", mr.waitingOn == nil ? "mine" : "others", mr.openThreads.map(String.init) ?? "", mr.verdictStale ? "stale" : ""].joined(separator: "|")
    }
    public static func isDismissed(_ mr: BoardMR, in stored: [String: String]) -> Bool { stored[mr.ref] == fingerprint(mr) }
    public static func dismiss(_ mr: BoardMR, in stored: [String: String]) -> [String: String] {
        var copy = stored; copy[mr.ref] = fingerprint(mr); return copy
    }
}
