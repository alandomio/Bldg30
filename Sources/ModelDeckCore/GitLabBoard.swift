import Foundation

public struct RawMR: Equatable, Sendable, Identifiable {
    public var id: String { ref }
    public let ref: String, title: String, role: String, pipeline: String, projectPath: String
    public let iid: Int, openThreads: Int
    public let url: URL
    public let updatedAt: Date
}

public enum GitLabBoard {
    static let fields = "iid title webUrl updatedAt reference(full: true) project { fullPath } headPipeline { status } resolvableDiscussionsCount resolvedDiscussionsCount"
    /// Authored and review-requested open MRs of the token owner, or of `username` when set.
    public static func query(username: String?) -> String {
        let root = username.map { _ in "user(username: $u)" } ?? "currentUser"
        let head = username.map { _ in "query($u: String!)" } ?? "query"
        return "\(head) { \(root) { authored: authoredMergeRequests(state: opened, first: 50) { nodes { \(fields) } } reviewing: reviewRequestedMergeRequests(state: opened, first: 50) { nodes { \(fields) } } } }"
    }

    /// Accepts `gitlab.example.com` or a full origin. Plain http is allowed for localhost only.
    public static func endpoint(host: String) throws -> URL {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let name = url.host?.lowercased(), !name.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw DeckError.rpc("Host GitLab non valido.") }
        let local = ["localhost", "127.0.0.1", "::1"].contains(name)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { throw DeckError.rpc("L’host GitLab deve usare https.") }
        return url
    }

    static func status(_ raw: String?) -> String {
        switch raw?.uppercased() {
        case "SUCCESS": "passed"
        case "FAILED": "failed"
        case "RUNNING": "running"
        case "PENDING", "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "SCHEDULED": "pending"
        case "CANCELED", "CANCELING": "canceled"
        case "MANUAL": "manual"
        case "SKIPPED": "skipped"
        case nil: "none"
        default: raw!.lowercased()
        }
    }

    /// Parses the GraphQL response. A malformed node throws, so a schema change never reads as "no MRs".
    public static func parse(_ data: Data) throws -> [RawMR] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            throw DeckError.rpc(first["message"] as? String ?? "GitLab ha restituito un errore.")
        }
        guard let user = (root["data"] as? [String: Any]).flatMap({ ($0["currentUser"] ?? $0["user"]) as? [String: Any] }) else { throw DeckError.invalidResponse }
        let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [RawMR] = []
        for (key, role) in [("authored", "author"), ("reviewing", "reviewer")] {
            guard let nodes = (user[key] as? [String: Any])?["nodes"] as? [[String: Any]] else { throw DeckError.invalidResponse }
            for node in nodes {
                guard let reference = node["reference"] as? String, let title = node["title"] as? String,
                      let link = node["webUrl"] as? String, let url = URL(string: link), url.scheme == "https",
                      let stamp = node["updatedAt"] as? String, let updated = dates.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
                      let project = (node["project"] as? [String: Any])?["fullPath"] as? String,
                      let iidText = node["iid"] as? String, let iid = Int(iidText) ?? (node["iid"] as? Int)
                else { throw DeckError.invalidResponse }
                guard !result.contains(where: { $0.ref == reference }) else { continue }
                let total = node["resolvableDiscussionsCount"] as? Int ?? 0, resolved = node["resolvedDiscussionsCount"] as? Int ?? 0
                result.append(RawMR(ref: reference, title: title, role: role, pipeline: status((node["headPipeline"] as? [String: Any])?["status"] as? String),
                                    projectPath: project, iid: iid, openThreads: max(0, total - resolved), url: url, updatedAt: updated))
            }
        }
        return result
    }

    public static func isMerged(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let state = root["state"] as? String else { throw DeckError.invalidResponse }
        return state == "merged"
    }
}

public struct RawBoard: Equatable, Sendable {
    public var tickets: [BoardTicket]
    public var mrs: [RawMR]
    public var linearOK: Bool, gitlabOK: Bool
    public var fetchedAt: Date
    public init(tickets: [BoardTicket] = [], mrs: [RawMR] = [], linearOK: Bool = false, gitlabOK: Bool = false, fetchedAt: Date = Date()) {
        self.tickets = tickets; self.mrs = mrs; self.linearOK = linearOK; self.gitlabOK = gitlabOK; self.fetchedAt = fetchedAt
    }
}

/// Read-only HTTP for the two pollers: no redirects, short timeouts, tokens only in headers.
public enum BoardHTTP {
    private final class Stay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func send(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: Stay(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DeckError.invalidResponse }
        guard response.statusCode == 200 else { throw DeckError.http(response.statusCode) }
        return data
    }
    static func graphQL(_ url: URL, query: String, variables: [String: String] = [:], authorization: String) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return try await send(request)
    }
}

extension LinearBoard {
    public static func fetch(key: String) async throws -> [BoardTicket] {
        try parse(try await BoardHTTP.graphQL(URL(string: "https://api.linear.app/graphql")!, query: query, authorization: key))
    }
}

extension GitLabBoard {
    public static func fetch(host: String, username: String, token: String) async throws -> [RawMR] {
        let base = try endpoint(host: host)
        let name = username.trimmingCharacters(in: .whitespaces)
        let data = try await BoardHTTP.graphQL(base.appendingPathComponent("api/graphql"), query: query(username: name.isEmpty ? nil : name),
                                               variables: name.isEmpty ? [:] : ["u": name], authorization: "Bearer " + token)
        return try parse(data)
    }
    public static func fetchMerged(host: String, token: String, projectPath: String, iid: Int) async throws -> Bool {
        let base = try endpoint(host: host)
        guard let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw DeckError.invalidResponse }
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v4/projects/\(encoded)/merge_requests/\(iid)") else { throw DeckError.invalidResponse }
        var request = URLRequest(url: url); request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        return try isMerged(try await BoardHTTP.send(request))
    }
}
