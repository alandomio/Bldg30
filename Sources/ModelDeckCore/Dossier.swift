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

    /// Open decisions and gotchas arrive as plain strings or as objects with a title (or text).
    private struct Note: Decodable {
        let text: String
        private struct Object: Decodable { let title: String?, text: String?, id: String? }
        init(from decoder: Decoder) throws {
            if let plain = try? decoder.singleValueContainer().decode(String.self) { text = plain; return }
            let object = try Object(from: decoder)
            text = object.title ?? object.text ?? object.id ?? ""
        }
    }
    private struct RawLink: Decodable { let label: String?, url: String? }
    private enum CodingKeys: String, CodingKey { case summary, timeline, openDecisions, gotchas, links, nextAction, generatedAt }
    /// Lists and texts may be omitted; only generated_at is required.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        timeline = try values.decodeIfPresent([Entry].self, forKey: .timeline) ?? []
        openDecisions = (try values.decodeIfPresent([Note].self, forKey: .openDecisions) ?? []).map(\.text).filter { !$0.isEmpty }
        gotchas = (try values.decodeIfPresent([Note].self, forKey: .gotchas) ?? []).map(\.text).filter { !$0.isEmpty }
        // Links may be https, file (local reports) or loopback http; anything else is dropped instead of invalidating the dossier.
        links = (try values.decodeIfPresent([RawLink].self, forKey: .links) ?? []).compactMap { raw in
            guard let text = raw.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "file" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else { return nil }
            return Link(label: raw.label ?? text, url: url)
        }
        nextAction = try values.decodeIfPresent(String.self, forKey: .nextAction) ?? ""
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
    }

    public enum Lookup: Equatable, Sendable { case missing, loaded(Dossier), invalid(String) }

    /// Lowercase, with runs of characters outside letters, digits, dot, dash and underscore as one dash: `svc !12` is `svc-12.json`, `IN-1` is `in-1.json`.
    public static func fileName(for ref: String) -> String {
        let cleaned = ref.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "-" }
        var text = ""
        for character in cleaned where !(character == "-" && text.last == "-") { text.append(character) }
        return text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-.")) + ".json"
    }

    public static func directory(feedPath: String) -> URL {
        URL(fileURLWithPath: (feedPath as NSString).expandingTildeInPath).deletingLastPathComponent().appendingPathComponent("dossiers", isDirectory: true)
    }

    public static func decode(_ data: Data) throws -> Dossier {
        let value: Dossier
        do { value = try CompanionFeed.jsonDecoder().decode(Dossier.self, from: data) }
        catch let error as CompanionError { throw error }
        catch { throw CompanionError.invalid(String(describing: error)) }
        return value
    }

    public static func lookup(ref: String, feedPath: String) -> Lookup {
        let file = directory(feedPath: feedPath).appendingPathComponent(fileName(for: ref))
        guard let data = FileManager.default.contents(atPath: file.path) else { return .missing }
        do { return .loaded(try decode(data)) } catch { return .invalid(error.localizedDescription) }
    }
}
