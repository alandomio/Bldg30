import SwiftUI
import AppKit
import ModelDeckCore

/// The Fleet view: every worker of every firstmate home, read from workers.json. Read-only: no control verbs here.
struct FleetView: View {
    @EnvironmentObject var store: DeckStore
    @AppStorage("fleetShowFinished") private var showFinished = false
    @State private var expanded: Set<String> = Set(Self.argument("--fleet-expand").map { $0.split(separator: ",").map(String.init) } ?? [])
    @State private var collapsed: Set<String> = Set(Self.argument("--fleet-collapsed").map { $0.split(separator: ",").map(String.init) } ?? [])

    private static func argument(_ name: String) -> String? {
        CommandArguments.value(after: name)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            content(now: timeline.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fleet = store.fleet {
                fileStatus(fleet, now: now)
                ForEach(fleet.machines, id: \.machine) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.machine).font(.system(size: 13, weight: .semibold)).foregroundStyle(DeckTheme.mint)
                        ForEach(group.homes) { home in homeSection(home, now: now) }
                    }
                }
                if fleet.homes.isEmpty { Text(L("Nessuna home nel file.")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
            } else {
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Nessun dato della flotta")).font(.system(size: 14, weight: .semibold))
                        Text(D(store.fleetError ?? CompanionSettings.fleetPath)).font(.system(size: 11, design: .monospaced)).foregroundStyle(DeckTheme.muted).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: file age

    private func fileStatus(_ fleet: FleetSnapshot, now: Date) -> some View {
        let stale = fleet.isStale(now: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusPill(text: stale ? "Dati della flotta non aggiornati" : "Dati della flotta aggiornati", color: stale ? DeckTheme.amber : DeckTheme.mint)
                Text(L("File di \(minutes(fleet.age(now: now))) fa")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                Spacer()
                Toggle(L("Mostra i finiti"), isOn: $showFinished).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
            }
            if stale { Text(L("Il file della flotta è vecchio: leggi con cautela.")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
            if let error = store.fleetError { Text(D(error)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        }
    }

    // MARK: one home

    @ViewBuilder private func homeSection(_ home: FleetHome, now: Date) -> some View {
        let open = !collapsed.contains(home.id)
        let rows = FleetSnapshot.rows(home.workers, showFinished: showFinished, now: now)
        DeckCard {
            VStack(alignment: .leading, spacing: 8) {
                Button { if open { collapsed.insert(home.id) } else { collapsed.remove(home.id) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                            Text(home.name).font(.system(size: 13, weight: .semibold))
                            Text(home.machine).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                            if home.remote { Text(L("remoto, sola lettura")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                            Spacer()
                            if let observed = home.observedAt { Text(L("osservato \(minutes(max(0, now.timeIntervalSince(observed)))) fa")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                        }
                        if home.ok { HStack(spacing: 6) { ForEach(home.counts, id: \.state) { entry in countPill(entry.state, entry.count) } } }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).pointerCursor()
                if !home.ok {
                    Label(L("Non raggiungibile: \(home.error ?? "—")"), systemImage: "wifi.exclamationmark").font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                } else if open {
                    if home.omitted > 0 { Text(L("\(home.omitted) lavoratori non elencati dalla home.")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
                    if home.workers.isEmpty { Text(L("Nessun lavoratore registrato.")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
                    else if rows.isEmpty { Text(L("Solo lavoratori finiti da più di 24 ore: attiva «Mostra i finiti».")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
                    ForEach(rows, id: \.rowID) { worker in row(worker, home: home, now: now) }
                    let hidden = home.workers.count - rows.count
                    if hidden > 0 { Text(L("\(hidden) finiti nascosti")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                }
            }
        }
    }

    private func countPill(_ state: FleetState, _ count: Int) -> some View {
        Text("\(count) " + label(state)).font(.system(size: 10, weight: .medium)).foregroundStyle(color(state))
            .padding(.horizontal, 7).padding(.vertical, 3).background(color(state).opacity(0.10), in: Capsule())
    }

    // MARK: one worker

    private func row(_ worker: FleetWorker, home: FleetHome, now: Date) -> some View {
        let key = home.id + "/" + worker.rowID
        let open = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 5) {
            Button { if open { expanded.remove(key) } else { expanded.insert(key) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusPill(text: label(worker.state), color: color(worker.state)).fixedSize()
                        Text(worker.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                        if !worker.kind.isEmpty { Text(worker.kind).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2).foregroundStyle(DeckTheme.muted).background(DeckTheme.subtle.opacity(0.08), in: Capsule()) }
                        if !worker.project.isEmpty { Text(worker.project).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).lineLimit(1) }
                        Text(worker.engine).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(age(worker.age(now: now))).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    }
                    if !worker.waitingOn.isEmpty {
                        Label(D(worker.waitingOn), systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
                            .lineLimit(open ? nil : 2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { details(worker) }
            let links = worker.links.compactMap(FleetLink.make)
            if !links.isEmpty { HStack(spacing: 6) { ForEach(Array(links.enumerated()), id: \.offset) { _, link in linkButton(link) } } }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(DeckTheme.subtle.opacity(worker.state.needsAttention ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func details(_ worker: FleetWorker) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !worker.detail.isEmpty { Text(D(worker.detail)).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            Text(L("Stato: \(worker.crewState.isEmpty ? "—" : worker.crewState)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
            if let last = worker.lastActivityAt { Text(L("Ultima attività: \(last.formatted(date: .abbreviated, time: .shortened))")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
        }.padding(.leading, 4)
    }

    private func linkButton(_ link: FleetLink) -> some View {
        switch link {
        case .web(let url, let name):
            return AnyView(Button(name) { NSWorkspace.shared.open(url) }.buttonStyle(DeckButtonStyle(small: true)).help(url.absoluteString))
        case .file(let url, let name):
            return AnyView(Button(name) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(DeckButtonStyle(small: true)).help(url.path))
        }
    }

    // MARK: words

    private func label(_ state: FleetState) -> String {
        switch state {
        case .working: L("In corso")
        case .waitingDecision: L("Aspetta una decisione")
        case .waitingPrompt: L("Aspetta un prompt")
        case .paused: L("In pausa")
        case .blocked: L("Bloccato")
        case .failed: L("Fallito")
        case .done: L("Finito")
        case .idle: L("Inattivo")
        case .stopped: L("Fermato")
        case .dead: L("Morto")
        case .unknown: L("Sconosciuto")
        }
    }
    private func color(_ state: FleetState) -> Color {
        switch state {
        case .waitingDecision, .waitingPrompt, .blocked: DeckTheme.amber
        case .failed, .dead: .red
        case .working: DeckTheme.mint
        case .paused: DeckTheme.blue
        default: DeckTheme.muted
        }
    }
    private func minutes(_ seconds: TimeInterval) -> String {
        guard let m = FleetAge.minutes(seconds) else { return "—" }
        return m < 1 ? L("meno di 1 min") : m < 120 ? L("\(m) min") : L("\(m / 60) h")
    }
    private func age(_ seconds: TimeInterval?) -> String {
        guard let m = FleetAge.minutes(seconds) else { return "—" }
        return m < 1 ? L("ora") : m < 120 ? L("\(m) min") : m < 60 * 48 ? L("\(m / 60) h") : L("\(m / 1440) giorni")
    }
}
