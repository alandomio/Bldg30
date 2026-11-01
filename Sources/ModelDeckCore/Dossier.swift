import Foundation

/// `companion/dossiers/<ref>.json` beside feed.json: a read-only view; Purser, PP Brain and Linear stay the sources of truth.
public struct Dossier: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable { public let at: String?, text: String }
    public struct Link: Decodable, Equatable, Sendable { public let label: String; public let url: URL }
    public let summary: String
    public let timeline: [Entry]
    public let openDecisions: [String]
    public let gotchas: [String]
    public let links: [Link]
    public let nextAction: String
    public let generatedAt: Date

    private enum CodingKeys: String, CodingKey { case summary, timeline, openDecisions, gotchas, links, nextAction, generatedAt }
    /// Lists and texts may be omitted; only generated_at is required.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        timeline = try values.decodeIfPresent([Entry].self, forKey: .timeline) ?? []
        openDecisions = try values.decodeIfPresent([String].self, forKey: .openDecisions) ?? []
        gotchas = try values.decodeIfPresent([String].self, forKey: .gotchas) ?? []
        links = try values.decodeIfPresent([Link].self, forKey: .links) ?? []
        nextAction = try values.decodeIfPresent(String.self, forKey: .nextAction) ?? ""
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
    }

    public enum Lookup: Equatable, Sendable { case missing, loaded(Dossier), invalid(String) }

    /// Runs of characters outside letters, digits, dot, dash and underscore become one dash: `svc !12` is `svc-12.json`.
    public static func fileName(for ref: String) -> String {
        let cleaned = ref.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "-" }
        var text = ""
        for character in cleaned where !(character == "-" && text.last == "-") { text.append(character) }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "-.")) + ".json"
    }

    public static func directory(feedPath: String) -> URL {
        URL(fileURLWithPath: (feedPath as NSString).expandingTildeInPath).deletingLastPathComponent().appendingPathComponent("dossiers", isDirectory: true)
    }

    public static func decode(_ data: Data) throws -> Dossier {
        let value: Dossier
        do { value = try CompanionFeed.jsonDecoder().decode(Dossier.self, from: data) }
        catch let error as CompanionError { throw error }
        catch { throw CompanionError.invalid(String(describing: error)) }
        if let bad = value.links.first(where: { $0.url.scheme != "https" }) { throw CompanionError.invalid("link non https: \(bad.label)") }
        return value
    }

    public static func lookup(ref: String, feedPath: String) -> Lookup {
        let file = directory(feedPath: feedPath).appendingPathComponent(fileName(for: ref))
        guard let data = FileManager.default.contents(atPath: file.path) else { return .missing }
        do { return .loaded(try decode(data)) } catch { return .invalid(error.localizedDescription) }
    }
}
