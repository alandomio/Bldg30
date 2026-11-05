import SwiftUI
import ModelDeckCore

/// Re-reads live.json every 5 s while the Live view is open and asks the producer for a fresh file when it is stale.
@MainActor final class LiveModel: ObservableObject {
    @Published var live: CompanionLive?
    @Published var error: String?
    @Published var running = false
    private var task: Task<Void, Never>?
    private var lastRun: Date?

    static var scriptPath: String { UserDefaults.standard.string(forKey: "liveScriptPath").flatMap { $0.isEmpty ? nil : $0 } ?? CompanionLive.defaultScript }
    static var path: String { CompanionLive.path(besideFeed: CompanionSettings.feedPath) }

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

    private func read() {
        do { let value = try CompanionLive.read(path: Self.path); if value != live { live = value }; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func tick() async {
        read()
        guard CompanionLive.shouldRun(generatedAt: live?.generatedAt, lastRun: lastRun) else { return }
        lastRun = Date(); running = true
        let result = await Shell.run("/usr/bin/python3", [Self.scriptPath, "live"], env: ["FM_HOME": CompanionLive.defaultHome], timeout: 10)
        running = false
        if result.ok { read() } else { error = L("Aggiornamento live non riuscito: \(WorkerBoard.firstLine(result.error.isEmpty ? result.output : result.error, limit: 160))") }
    }
}

struct LiveView: View {
    @EnvironmentObject var store: DeckStore
    @StateObject private var model = LiveModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in header(now: context.date) }
            if let error = model.error { Text(D(error)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
            let decisions = store.companionFeed?.decisions ?? []
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
