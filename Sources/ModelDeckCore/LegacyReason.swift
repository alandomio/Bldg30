import Foundation

/// A legacy hold reason is one string: "What and where: ... Why now: ... Options: (a) ... (b) ... Recommendation: ... Detail: <paths>".
/// The producer splits it into the decision block; this does the same for a feed that still carries the plain string.
public enum LegacyReason {
    static let labels = ["What and where", "Why now", "Options", "Recommendation", "Detail", "Links"]
    static let pattern = try! NSRegularExpression(pattern: #"(?:^|(?<=[.!?)]\s)|(?<=\n))(What and where|Why now|Options|Recommendation|Detail|Links):\s*"#)

    /// [(label, text)] in order; empty unless at least two labels are present.
    public static func sections(_ text: String) -> [(label: String, text: String)] {
        let source = text.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = source as NSString
        let hits = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard hits.count >= 2 else { return [] }
        return hits.enumerated().map { index, hit in
            let end = index + 1 < hits.count ? hits[index + 1].range.location : ns.length
            let start = hit.range.location + hit.range.length
            return (ns.substring(with: hit.range(at: 1)), ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// GitLab MR links as "repo !N", local file paths removed, first letter capital.
    public static func readable(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"https://[^\s/]+/(?:[\w.-]+/)*?([\w.-]+)/-/merge_requests/(\d+)"#, with: "$1 !$2", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b([\w.-]+) (?:merge request|MR) \1 !"#, with: "$1 !", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![\w:/])/(?:Users|private|tmp|var|Library|Volumes)/[^\s,;)]*"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^\(([a-h])\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([.,;])(?=\s|$)"#, with: "$1", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// "A. ..." lines when the options text has at least two (a)/(1)-style choices, else the readable text.
    static func optionLines(_ text: String) -> String {
        let ns = text as NSString
        let marker = try! NSRegularExpression(pattern: #"\((?:[a-h]|\d)\)\s*"#, options: .caseInsensitive)
        let hits = marker.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard hits.count >= 2 else { return readable(text) }
        let lines = hits.enumerated().map { index, hit -> String in
            let end = index + 1 < hits.count ? hits[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: hit.range.location + hit.range.length, length: end - hit.range.location - hit.range.length))
            return String(UnicodeScalar(UInt8(65 + index))) + ". " + readable(body.trimmingCharacters(in: CharacterSet(charactersIn: " ;,.")))
        }
        return lines.joined(separator: "\n")
    }

    /// Title and headed paragraphs for a legacy reason, nil when the text is not in the labelled shape.
    public static func parse(_ text: String, rowTitle: String? = nil, id: String = "") -> (title: String, parts: [CompanionFeed.SummaryPart])? {
        let found = sections(text)
        guard !found.isEmpty else { return nil }
        var by: [String: String] = [:]
        for (label, body) in found where by[label] == nil { by[label] = body }
        let parts = ["What and where", "Why now", "Options", "Recommendation"].compactMap { label -> CompanionFeed.SummaryPart? in
            guard let body = by[label], !body.isEmpty else { return nil }
            let value = label == "Options" ? optionLines(body) : readable(body)
            return value.isEmpty ? nil : CompanionFeed.SummaryPart(heading: label, text: value)
        }
        return (title(what: by["What and where"] ?? "", rowTitle: rowTitle, id: id), parts)
    }

    static func title(what: String, rowTitle: String?, id: String) -> String {
        if let rowTitle, rowTitle != id, rowTitle.contains(" ") { return rowTitle }
        let ref = what.range(of: #"([\w.-]+)/-/merge_requests/(\d+)"#, options: .regularExpression).map { range -> String in
            let parts = what[range].components(separatedBy: "/-/merge_requests/"); return "\(parts[0].split(separator: "/").last ?? "") !\(parts[1])"
        }
        let bare = what.replacingOccurrences(of: #"https://\S+"#, with: "", options: .regularExpression)
        if let ref, let open = bare.range(of: #"\(([^()]{8,100})\)"#, options: .regularExpression) {
            let inner = String(bare[open].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return ref + ": " + inner.prefix(1).uppercased() + inner.dropFirst()
        }
        var clause = readable(what).replacingOccurrences(of: #"^(?i)(decide|choose|confirm)\s+(what to do with|whether to|whether|where|how to|if)?\s*"#, with: "", options: .regularExpression)
        clause = clause.components(separatedBy: CharacterSet(charactersIn: ".;")).first ?? clause
        if clause.count > 80 { clause = String(clause.prefix(80)).components(separatedBy: " ").dropLast().joined(separator: " ") }
        clause = clause.trimmingCharacters(in: .whitespaces)
        return clause.isEmpty ? (rowTitle ?? id) : clause.prefix(1).uppercased() + clause.dropFirst()
    }
}
