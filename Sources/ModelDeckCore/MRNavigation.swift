import Foundation

/// Paging of MR cards and of the drafts inside one card.
public enum Pager {
    /// The next index after moving `step` places. MR cards wrap round; the draft pager stops at its ends.
    public static func move(_ index: Int, by step: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        if wrap { return ((current + step) % count + count) % count }
        return min(max(current + step, 0), count - 1)
    }
    /// "3 of 48" numbers, 1-based; the index is clamped into the list.
    public static func label(_ index: Int, count: Int) -> (position: Int, total: Int) { (min(max(index, 0), max(count - 1, 0)) + 1, count) }
    public static func canMove(_ index: Int, by step: Int, count: Int) -> Bool {
        count > 0 && (0..<count).contains(index + step)
    }
}

/// The Linear ticket of an MR card: its id and where it links to.
public enum MRTicket {
    /// The first Linear-style id in a text such as "IN-2566 · In Progress".
    public static func identifier(in text: String?) -> String? {
        guard let text, let range = text.range(of: #"[A-Z][A-Z0-9]{1,9}-\d+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }
    /// The feed's `ticket_url` when it is https, else the URL of a ticket row with that id; nil when neither exists (no invented links).
    public static func url(identifier: String, feedURL: String?, tickets: [BoardTicketRow]) -> URL? {
        if let text = CompanionFeed.text(feedURL), let url = URL(string: text), url.scheme == "https", url.host != nil { return url }
        return tickets.first { $0.identifier == identifier }?.url
    }
}
