import Foundation
import SwiftUI
import ModelDeckCore

/// The Workers tab's state: worker files read from the firstmate home, crew state from `fm-crew-state.sh`, and the
/// safe control verbs. Nothing here writes to firstmate's files; clicks go through the click inbox (`DeckStore`).
@MainActor final class WorkersModel: ObservableObject {
    enum Panel: Equatable { case peek, steer, answer, relaunch, review }

    @Published private(set) var workers: [Worker] = []
    @Published private(set) var refreshing = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var lastRefresh: Date?
    @Published var panel: [String: Panel] = [:]
    @Published var tails: [String: String] = [:]
    @Published var prompts: [String: WorkerPrompt] = [:]
    @Published var running: [String: String] = [:]      // task -> the verb being run
    @Published var result: [String: String] = [:]       // task -> what the last verb said
    @Published var text: [String: String] = [:]         // steer and relaunch text boxes

    let runner = WorkerRunner()
    private var crew: [String: (state: CrewState, at: Date)] = [:]
    private var seeds: [String: (meta: WorkerMeta, events: [StatusEvent])] = [:]
    private var drafts: [String: Int] = [:]
    private var holds: [String: [String]] = [:]
    private var ledger = CommandLedger()
    private var loop: Task<Void, Never>?

    var available: Bool { runner.available }
    var supportsAnswer: Bool { runner.supportsAnswer && runner.supportsPrompt }
    var home: String { runner.home }

    static var cacheURL: URL {
        if let path = CommandArguments.value(after: "--workers-cache") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelDeck/workers-crew.json")
    }

    /// Last crew states, so the tab opens filled and the refresh only corrects it.
    func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (task, item) in raw {
            guard let kind = (item["kind"] as? String).flatMap(CrewState.Kind.init(rawValue:)), let at = item["at"] as? Double else { continue }
            crew[task] = (CrewState(kind: kind, source: item["source"] as? String ?? "", detail: item["detail"] as? String ?? ""), Date(timeIntervalSince1970: at))
        }
    }
    private func saveCache() {
        let raw = crew.mapValues { ["kind": $0.state.kind.rawValue, "source": $0.state.source, "detail": $0.state.detail, "at": $0.at.timeIntervalSince1970] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    /// Re-reads the worker files and rebuilds the list from what is known now.
    func reload(mrs: [BoardMR], ledger: CommandLedger, discarded: Set<String>, decisions: [(id: String, title: String)] = []) {
        self.ledger = ledger
        drafts = WorkerBoard.unposted(mrs: mrs, ledger: ledger, discarded: discarded)
        let home = runner.home
        seeds = Dictionary(uniqueKeysWithValues: WorkerBoard.ids(home: home).compactMap { id in WorkerBoard.load(id: id, home: home).map { (id, $0) } })
        holds = WorkerBoard.feedDecisions(decisions, workers: Array(seeds.keys))
        rebuild()
    }
    private func rebuild() {
        let now = Date()
        workers = seeds.values.map { seed in
            Worker(meta: seed.meta, crew: crew[seed.meta.id]?.state, events: seed.events, unpostedDrafts: drafts[seed.meta.id] ?? 0,
                   refusedCleanup: WorkerBoard.refusedCleanup(task: seed.meta.id, ledger: ledger), feedDecisions: holds[seed.meta.id] ?? [], now: now)
        }.sorted { $0.id < $1.id }
    }

    /// Refreshes crew states a few at a time: the active ones often, the rest rarely.
    func refresh(force: Bool = false) async {
        guard available, !refreshing else { return }
        let now = Date()
        let due = seeds.values.map(\.meta).filter { !$0.isRemote }.filter { meta in
            guard !force, let known = crew[meta.id] else { return true }
            let ttl: TimeInterval = [.working, .blocked, .unknown].contains(known.state.kind) ? 25 : 600
            return now.timeIntervalSince(known.at) > ttl
        }.map(\.id)
        guard !due.isEmpty else { return }
        refreshing = true; progress = (0, due.count)
        let runner = self.runner
        await runner.refresh(due) { task, state in await self.record(task, state) }
        rebuild(); saveCache(); refreshing = false; lastRefresh = Date()
    }
    private func record(_ task: String, _ state: CrewState?) {
        if let state { crew[task] = (state, Date()) }
        progress.done += 1
        if progress.done % 8 == 0 || progress.done == progress.total { rebuild() }
    }
    /// One worker, right after a verb touched it.
    func refreshOne(_ task: String) async {
        if let state = await runner.crewState(task) { crew[task] = (state, Date()); rebuild(); saveCache() }
    }

    /// Reads the cache and the files, then keeps refreshing while the tab is on screen.
    func start(mrs: @escaping () -> [BoardMR], ledger: @escaping () -> CommandLedger, discarded: @escaping () -> Set<String>, decisions: @escaping () -> [(id: String, title: String)]) {
        loadCache(); reload(mrs: mrs(), ledger: ledger(), discarded: discarded(), decisions: decisions())
        guard !CommandLine.arguments.contains("--workers-no-refresh") else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reload(mrs: mrs(), ledger: ledger(), discarded: discarded(), decisions: decisions())
                await self.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    // MARK: the safe verbs, run here

    func toggle(_ panelKind: Panel, for task: String) {
        if panel[task] == panelKind { panel[task] = nil; return }
        panel[task] = panelKind
        if panelKind == .peek || panelKind == .answer || panelKind == .review { Task { await loadTail(task) } }
        if panelKind == .answer { Task { await loadPrompt(task) } }
    }
    func loadTail(_ task: String) async { tails[task] = await runner.peek(task, lines: 40) }
    func loadPrompt(_ task: String) async { prompts[task] = await runner.prompt(task) }

    func control(_ verb: WorkerRunner.Verb, task: String) {
        running[task] = verb.rawValue; result[task] = nil
        Task {
            let outcome = await runner.control(task, verb)
            running[task] = nil
            result[task] = outcome.ok ? (verb == .exit ? "Stopped. The local copy is kept." : "Interrupted.") : Self.reason(outcome)
            await refreshOne(task)
        }
    }
    func relaunch(task: String) {
        let note = (text[task + ".relaunch"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { result[task] = "Write what the new agent should know first."; return }
        running[task] = "relaunch"; result[task] = nil
        Task {
            let outcome = await runner.relaunch(task, note: note)
            running[task] = nil
            result[task] = outcome.ok ? "Relaunched in the same local copy." : Self.reason(outcome)
            if outcome.ok { panel[task] = nil; text[task + ".relaunch"] = nil }
            await refreshOne(task)
        }
    }
    func answer(task: String, option: WorkerPrompt.Option, prompt: WorkerPrompt) {
        running[task] = "answer"; result[task] = nil
        Task {
            let outcome = await runner.answer(task, option: option.id, sha: prompt.sha)
            running[task] = nil
            result[task] = outcome.ok ? "Answered “\(option.label)”." : Self.reason(outcome)
            if outcome.ok { panel[task] = nil; prompts[task] = nil }
            await refreshOne(task)
        }
    }
    func openTerminal(_ meta: WorkerMeta) {
        Task { let outcome = await runner.openTerminal(meta); result[meta.id] = outcome.ok ? "Opened its terminal pane." : Self.reason(outcome) }
    }
    func openEditor(_ meta: WorkerMeta) {
        guard !meta.worktree.isEmpty else { result[meta.id] = "No local copy is recorded."; return }
        Task { let outcome = await runner.openEditor(meta.worktree); result[meta.id] = outcome.ok ? nil : Self.reason(outcome) }
    }
    func reportURL(_ meta: WorkerMeta) -> URL? {
        let file = URL(fileURLWithPath: home).appendingPathComponent("data/\(meta.id)/report.md")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    /// The first merge request link in the worker's last done or paused line.
    func mrURL(_ worker: Worker) -> URL? {
        let text = worker.events.reversed().prefix(6).map(\.text).joined(separator: " ")
        guard let range = text.range(of: #"https://gitlab\.com/[^\s)"'>]+/-/merge_requests/\d+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    static func reason(_ outcome: ExecResult) -> String {
        if outcome.timedOut { return "Took too long and was stopped." }
        let message = (outcome.error.isEmpty ? outcome.output : outcome.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Failed (exit \(outcome.status))." : String(message.suffix(300))
    }
}
