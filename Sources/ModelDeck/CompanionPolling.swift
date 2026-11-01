import Foundation
import ModelDeckCore

extension CompanionSettings {
    static var linearOn: Bool { UserDefaults.standard.bool(forKey: "boardEnabled") }
    static var gitlabOn: Bool { UserDefaults.standard.bool(forKey: "gitlabEnabled") }
    static var gitlabHost: String { UserDefaults.standard.string(forKey: "gitlabHost") ?? "" }
    static var gitlabUser: String { UserDefaults.standard.string(forKey: "gitlabUsername") ?? "" }
    static var eventsPath: String { UserDefaults.standard.string(forKey: "companionEventsPath") ?? "" }
    static let pollInterval: TimeInterval = 120
}

extension DeckStore {
    var boardMRs: [BoardMR] { CompanionBoard.mrs(feed: companionFeed, raw: rawBoard) }
    var boardTickets: [BoardTicketRow] { CompanionBoard.tickets(feed: companionFeed, raw: rawBoard) }

    /// Polls Linear and GitLab while the app is open. A failed source keeps its last rows and reports the error.
    func pollBoard() async {
        guard !demo, !polling, CompanionSettings.enabled else { return }
        guard lastPoll.map({ Date().timeIntervalSince($0) >= CompanionSettings.pollInterval }) ?? true else { return }
        let linearKey = CompanionSettings.linearOn ? DeckKeychain.read(account: "linear") : nil
        let gitlabToken = CompanionSettings.gitlabOn ? DeckKeychain.read(account: "gitlab") : nil
        guard linearKey != nil || gitlabToken != nil else { rawBoard = nil; pollError = nil; return }
        polling = true; defer { polling = false }; lastPoll = Date()
        var board = RawBoard(tickets: rawBoard?.tickets ?? [], mrs: rawBoard?.mrs ?? [], fetchedAt: Date())
        var problems: [String] = []
        if let linearKey {
            do { board.tickets = try await LinearBoard.fetch(key: linearKey); board.linearOK = true }
            catch { problems.append("Linear: " + error.localizedDescription) }
        } else { board.tickets = [] }
        if let gitlabToken {
            do { board.mrs = try await GitLabBoard.fetch(host: CompanionSettings.gitlabHost, username: CompanionSettings.gitlabUser, token: gitlabToken); board.gitlabOK = true }
            catch { problems.append("GitLab: " + error.localizedDescription) }
        } else { board.mrs = [] }
        let change = CompanionDiff.events(old: rawBoard, new: board)
        for event in change.events { batcher.add(event) }
        if let gitlabToken {
            for gone in change.vanished where (try? await GitLabBoard.fetchMerged(host: CompanionSettings.gitlabHost, token: gitlabToken, projectPath: gone.projectPath, iid: gone.iid)) == true {
                batcher.add(CompanionEvent(kind: "mr_merged", ref: gone.ref, source: "gitlab", state: "merged"))
            }
        }
        rawBoard = board; pollError = problems.isEmpty ? nil : problems.joined(separator: " · ")
    }

    func flushEvents() {
        let path = CompanionSettings.eventsPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let lines = batcher.flush() else { return }
        do { try CompanionEventFile.append(lines, to: path) } catch { pollError = error.localizedDescription }
    }

    func dossier(for ref: String) -> Dossier.Lookup { Dossier.lookup(ref: ref, feedPath: CompanionSettings.feedPath) }
}
