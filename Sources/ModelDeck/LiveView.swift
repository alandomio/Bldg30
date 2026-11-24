import SwiftUI
import ModelDeckCore

struct LiveConfiguration: Equatable {
    let home: String, feedPath: String, scriptPath: String
    init(home: String, feedPath: String, scriptPath: String? = nil) {
        self.home = WorkerRunner(home: home).home
        self.feedPath = URL(fileURLWithPath: (feedPath as NSString).expandingTildeInPath).path
        let script = scriptPath.flatMap { $0.isEmpty ? nil : $0 } ?? self.home + "/data/shipdeck-wire/bin/wire.py"
        self.scriptPath = (script as NSString).expandingTildeInPath
    }
    static var current: Self {
        Self(home: WorkerRunner.defaultHome, feedPath: CompanionSettings.feedPath,
             scriptPath: UserDefaults.standard.string(forKey: "liveScriptPath"))
    }
    var path: String { CompanionLive.path(besideFeed: feedPath) }
    var environment: [String: String] {
        ["FM_HOME": home, "SHIPDECK_COMPANION": URL(fileURLWithPath: feedPath).deletingLastPathComponent().path]
    }
}

struct LivePageContent {
    let decisions: [CompanionFeed.Decision]
    let decisionAge: TimeInterval?
    let decisionOutdated: Bool
    let decisionError: String?
    init(feed: CompanionFeed?, ledger: CommandLedger, error: String?, now: Date) {
        decisions = OpenDecisions.filter(feed?.decisions ?? [], ledger: ledger)
        decisionAge = feed?.age(now: now)
        decisionOutdated = feed?.isOutdated(now: now) ?? false
        decisionError = error
    }
}

/// Re-reads live.json every 5 s while the Live view is open and asks the producer for a fresh file when it is stale.
@MainActor final class LiveModel: ObservableObject {
    @Published var live: CompanionLive?
    @Published var error: String?
    @Published var running = false
    private var task: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastRun: Date?
    private let configuration: () -> LiveConfiguration
    private let readLive: (String) throws -> CompanionLive
    private let run: (String, [String], [String: String], TimeInterval) async -> ExecResult
    private let now: () -> Date

    init(configuration: @escaping () -> LiveConfiguration = { .current },
         read: @escaping (String) throws -> CompanionLive = { try CompanionLive.read(path: $0) },
         run: @escaping (String, [String], [String: String], TimeInterval) async -> ExecResult = {
             await Shell.run($0, $1, env: $2, timeout: $3)
         }, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration; readLive = read; self.run = run; self.now = now
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                await tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    private func read(path: String) {
        do { let value = try readLive(path); if value != live { live = value }; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func tick() async {
        let config = configuration()
        read(path: config.path)
        if let refreshTask { await refreshTask.value; return }
        guard CompanionLive.shouldRun(generatedAt: live?.generatedAt, lastRun: lastRun, now: now()) else { return }
        lastRun = now(); running = true
        // Section navigation cancels polling, but the store owns this model and the separate producer task until completion.
        let refresh = Task {
            let result = await run("/usr/bin/python3", [config.scriptPath, "live"], config.environment, 10)
            running = false
            if result.ok { read(path: config.path) }
            else { error = L("Aggiornamento live non riuscito: \(WorkerBoard.firstLine(result.error.isEmpty ? result.output : result.error, limit: 160))") }
            refreshTask = nil
        }
        refreshTask = refresh
        await refresh.value
    }
}

struct LiveView: View {
    @EnvironmentObject var store: DeckStore
    @ObservedObject var model: LiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in header(now: context.date) }
            TimelineView(.periodic(from: .now, by: 1)) { context in decisionStatus(content(now: context.date)) }
            if let error = model.error { Text(D(error)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
            let decisions = content(now: .now).decisions
            if !decisions.isEmpty {
                SectionLabel(title: L("DECISIONI APERTE"), trailing: "\(decisions.count)")
                ForEach(decisions) { decision in
                    DeckCard {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            badge("needs-decision")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(D(decision.displayTitle)).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                Text(D(decision.project)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                            }
                            Spacer()
                        }
                    }
                }
            }
            SectionLabel(title: L("EVENTI"), trailing: model.live.map { "\($0.events.count)" } ?? "")
            if let live = model.live {
                if live.events.isEmpty { Text(L("Nessun evento.")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
                ForEach(live.events) { event in
                    DeckCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                badge(event.state)
                                Text(event.task).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(relative(event.at)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                            }
                            Text(D(event.text)).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            } else if model.error == nil { ProgressView().controlSize(.small) }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func content(now: Date) -> LivePageContent {
        LivePageContent(feed: store.companionFeed, ledger: store.commandLedger, error: store.companionError, now: now)
    }

    private func decisionStatus(_ content: LivePageContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let age = content.decisionAge {
                HStack(spacing: 8) {
                    Text(L("Feed decisioni")).font(.system(size: 11, weight: .semibold))
                    if content.decisionOutdated {
                        StatusPill(text: L("Feed fermo da \(Int(age / 60)) min"), color: .red)
                    } else {
                        Text(L("feed.json aggiornato \(Int(age)) s fa")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    }
                }
            }
            if let error = content.decisionError {
                Text(L("Lettura feed decisioni non riuscita: \(error)")).font(.system(size: 11))
                    .foregroundStyle(DeckTheme.amber).textSelection(.enabled)
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            if let generated = model.live?.generatedAt {
                let age = max(0, Int(now.timeIntervalSince(generated)))
                Circle().fill(age > 30 ? DeckTheme.amber : DeckTheme.mint).frame(width: 7, height: 7)
                Text(L("live.json aggiornato \(age) s fa")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            } else { Text(L("live.json non ancora letto")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            if model.running { ProgressView().controlSize(.small); Text(L("Aggiorno")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            Spacer()
            Text(L("Lettura ogni 5 s")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
        }
    }

    private func badge(_ state: String) -> some View {
        let color: Color
        switch CompanionLive.tone(of: state) {
        case .decision: color = DeckTheme.purple
        case .good: color = DeckTheme.mint
        case .active: color = DeckTheme.blue
        case .warning: color = DeckTheme.amber
        case .bad: color = .red
        case .neutral: color = DeckTheme.muted
        }
        return Text(state).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.13), in: Capsule())
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = DeckLanguage.current.locale; formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
