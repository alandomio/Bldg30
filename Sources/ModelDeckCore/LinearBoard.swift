import Foundation

public struct BoardTicket: Equatable, Sendable, Identifiable {
    public let id: String
    public let identifier: String
    public let title: String
    public let state: String
    public let url: URL
    public let updatedAt: Date
}

public enum LinearBoard {
    public static let query = "query { viewer { assignedIssues(first: 100, filter: { state: { type: { nin: [\"completed\", \"canceled\"] } } }) { nodes { id identifier title url updatedAt state { name type } } } } }"
    static let closedStates: Set<String> = ["completed", "canceled"]

    /// Parses the GraphQL `viewer.assignedIssues` response. A malformed node throws instead of being dropped, so a schema change never reads as "no tickets".
    public static func parse(_ data: Data) throws -> [BoardTicket] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            throw DeckError.rpc(first["message"] as? String ?? "Linear ha restituito un errore.")
        }
        guard let nodes = (((root["data"] as? [String: Any])?["viewer"] as? [String: Any])?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] else { throw DeckError.invalidResponse }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try nodes.compactMap { node in
            guard let id = node["id"] as? String, let identifier = node["identifier"] as? String, let title = node["title"] as? String,
                  let link = node["url"] as? String, let url = URL(string: link), url.scheme == "https",
                  let stamp = node["updatedAt"] as? String, let updatedAt = dates.date(from: stamp),
                  let state = node["state"] as? [String: Any], let name = state["name"] as? String, let type = state["type"] as? String
            else { throw DeckError.invalidResponse }
            guard !closedStates.contains(type) else { return nil }
            return BoardTicket(id: id, identifier: identifier, title: title, state: name, url: url, updatedAt: updatedAt)
        }
    }
}
