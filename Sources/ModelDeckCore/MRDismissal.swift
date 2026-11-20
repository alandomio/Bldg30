import Foundation

/// The banner line and the dismissal rule of an MR card, both read from live facts of the feed row.
public enum MRDismissal {
    /// "Approved by omar.pp · 0 left · waiting on kmang to merge". "You" only when the user approved. Nil when nobody approved.
    public static func banner(approval: CompanionFeed.Approval?, waitingOn: String?) -> String? {
        guard let badge = approval?.badge else { return nil }
        let names = (badge.byMe ? ["you"] : []) + badge.others
        var line = "Approved by " + names.joined(separator: ", ")
        if let left = approval?.approvalsLeft { line += " · \(left) left" }
        if let who = CompanionFeed.text(waitingOn) { line += " · waiting on \(who) to merge" }
        return line
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
