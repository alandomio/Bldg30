import SwiftUI
import AppKit
import ModelDeckCore

/// The Workers tab: every worker of this firstmate home in six groups. The safe control verbs run here; cleanup,
/// discard, merge, steer text and spawn are clicks for firstmate.
struct WorkersView: View {
    @EnvironmentObject var store: DeckStore
    @StateObject private var model = WorkersModel()
    var openDecisions: () -> Void = {}

    private enum Confirm: Identifiable {
        case sweepAll([Worker]), discard(Worker), exit(Worker), interrupt(Worker)
        var id: String {
            switch self {
            case .sweepAll: "sweep-all"
            case .discard(let w): "discard-" + w.id
            case .exit(let w): "exit-" + w.id
            case .interrupt(let w): "interrupt-" + w.id
            }
        }
    }
    @State private var confirm: Confirm?
    @State private var feedback: String?
    @State private var closedGroups: Set<String> = CommandLine.arguments.contains("--workers-open-all") ? [] : [WorkerGroup.stale.rawValue, WorkerGroup.remote.rawValue]

    private var discardedReview: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "discardedReviewDrafts") ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.available {
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Cartella di firstmate non trovata")).font(.system(size: 14, weight: .semibold))
                        Text(D(model.home)).font(.system(size: 11, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    }
                }
            }
            ForEach(WorkerBoard.grouped(model.workers), id: \.0) { group, members in
                section(group, members)
            }
            if model.workers.isEmpty && model.available { Text(L("Nessun lavoratore registrato.")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
            if let feedback { Text(D(feedback)).font(.system(size: 12)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        }
        .onAppear { model.start(mrs: { store.boardMRs }, ledger: { store.commandLedger }, discarded: { discardedReview }, decisions: { (store.companionFeed?.decisions ?? []).map { ($0.id, $0.displayTitle) } }) }
        .onDisappear { model.stop() }
        .onChange(of: store.commandLedger) { _ in model.reload(mrs: store.boardMRs, ledger: store.commandLedger, discarded: discardedReview, decisions: (store.companionFeed?.decisions ?? []).map { ($0.id, $0.displayTitle) }) }
        .alert(item: $confirm, content: alert)
    }

    // MARK: header and groups

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("\(model.workers.count) lavoratori in \(URL(fileURLWithPath: model.home).lastPathComponent)")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted)
            if model.refreshing { ProgressView().controlSize(.small); Text(L("Aggiorno \(model.progress.done) di \(model.progress.total)")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            else if let last = model.lastRefresh { Text(L("Aggiornato \(relative(last))")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            Spacer()
            Button(L("Aggiorna")) { Task { await model.refresh(force: true) } }.buttonStyle(DeckButtonStyle(small: true)).disabled(model.refreshing || !model.available)
        }
    }

    private func title(_ group: WorkerGroup) -> String {
        switch group {
        case .needsYou: L("Serve te")
        case .working: L("In corso")
        case .done: L("Finiti")
        case .waiting: L("In pausa dichiarata")
        case .stale: L("Fermi da più di 24 ore")
        case .remote: L("Remoti (sola lettura)")
        }
    }

    @ViewBuilder private func section(_ group: WorkerGroup, _ members: [Worker]) -> some View {
        let open = Binding(get: { !closedGroups.contains(group.rawValue) }, set: { if $0 { closedGroups.remove(group.rawValue) } else { closedGroups.insert(group.rawValue) } })
        let sweepable = members.filter(\.sweepable)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { open.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text(title(group)).font(.system(size: 13, weight: .semibold)).foregroundStyle(group == .needsYou ? DeckTheme.amber : DeckTheme.mint)
                        Text("\(members.count)").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    }
                }.buttonStyle(.plain).pointerCursor()
                Spacer()
                if (group == .done || group == .stale), !sweepable.isEmpty {
                    Button(L("Sweep tutti (\(sweepable.count))")) { confirm = .sweepAll(sweepable) }.buttonStyle(DeckButtonStyle(small: true))
                }
            }
            if open.wrappedValue { ForEach(members) { card($0) } }
        }
    }

    // MARK: one worker

    private func card(_ worker: Worker) -> some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(worker.id).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(worker.meta.kind).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2).foregroundStyle(DeckTheme.muted).background(DeckTheme.subtle.opacity(0.08), in: Capsule())
                    Text([worker.meta.harness, worker.meta.model].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    Spacer()
                    if let last = worker.lastActivity { Text(relative(last)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                }
                // Done workers lead with the verdict: sweeping counts as having seen it.
                if worker.group == .done || worker.group == .stale, let verdict = worker.verdict {
                    Text(D(verdict)).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if !worker.activity.isEmpty {
                    Text(D(worker.activity)).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                needs(worker)
                if let blocker = worker.sweepBlocker, worker.group == .done || worker.group == .stale {
                    Text(L("Niente sweep: \(blocker)")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
                }
                status(worker)
                if let message = model.result[worker.id] { Text(D(message)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
                panels(worker)
                if !worker.meta.isRemote { buttons(worker) }
            }
        }
    }

    @ViewBuilder private func needs(_ worker: Worker) -> some View {
        ForEach(Array(worker.needs.enumerated()), id: \.offset) { _, need in
            switch need {
            case .stuckPrompt: Label(L("Aspetta una risposta a un prompt"), systemImage: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DeckTheme.amber)
            case .decision(let text): Label(D(WorkerBoard.firstLine(text, limit: 200)), systemImage: "questionmark.bubble.fill").font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
            case .cleanupRefused(let note): Label(L("Pulizia rifiutata: \(WorkerBoard.firstLine(note, limit: 240))"), systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
            }
        }
    }

    /// What firstmate did with the last click on this worker; after a steer, whether the worker is working again.
    @ViewBuilder private func status(_ worker: Worker) -> some View {
        if let command = store.commandLedger.latest(target: WorkerActions.target(worker.id)) {
            let steer = command.actionID == WorkerActions.steer
            switch command.state {
            case .queued: StatusPill(text: D("In coda per firstmate"), color: DeckTheme.amber)
            case .pickedUp: StatusPill(text: D("Firstmate ci sta lavorando"), color: DeckTheme.blue)
            case .failed: StatusPill(text: D(WorkerBoard.firstLine(command.note ?? "Non riuscito", limit: 120)), color: .red)
            case .done:
                if steer { StatusPill(text: D(worker.group == .working ? "Di nuovo al lavoro" : "Consegnato, non ancora al lavoro"), color: worker.group == .working ? DeckTheme.mint : DeckTheme.amber) }
                else if command.actionID == WorkerActions.sweep || command.actionID == WorkerActions.cleanup { StatusPill(text: D("Fatto"), color: DeckTheme.mint) }
            }
        }
    }

    // MARK: panels

    @ViewBuilder private func panels(_ worker: Worker) -> some View {
        switch model.panel[worker.id] {
        case .peek: tailBox(worker.id)
        case .steer:
            box { textEntry(key: worker.id + ".steer", prompt: L("Cosa deve fare in più o diversamente?"), send: L("Invia a firstmate")) { text in
                guard let click = WorkerActions.steerClick(task: worker.id, text: text) else { return }
                let error = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: text)
                feedback = error
                if error == nil {
                    model.panel[worker.id] = nil
                    model.text[worker.id + ".steer"] = nil
                }
            } }
        case .relaunch:
            box { textEntry(key: worker.id + ".relaunch", prompt: L("Nota per il nuovo agente (cosa è fatto, cosa resta)"), send: L("Rilancia")) { _ in model.relaunch(task: worker.id) } }
        case .answer: answerBox(worker)
        case .review: reviewBox(worker)
        case nil: EmptyView()
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(DeckTheme.subtle.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tailBox(_ task: String) -> some View {
        box {
            Text(L("Ultime righe del terminale")).font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTheme.muted)
            ScrollView { Text(model.tails[task] ?? "…").font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 190)
        }
    }

    private func textEntry(key: String, prompt: String, send label: String, action: @escaping (String) -> Void) -> some View {
        let binding = Binding(get: { model.text[key] ?? "" }, set: { model.text[key] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            Text(prompt).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            TextEditor(text: binding).font(.system(size: 12)).frame(minHeight: 60).scrollContentBackground(.hidden)
            Button(label) { action(binding.wrappedValue) }.buttonStyle(DeckButtonStyle(primary: true, small: true)).disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The exact prompt and its options when `fm-control.sh … prompt` exists; the pane tail and an Open button until then.
    @ViewBuilder private func answerBox(_ worker: Worker) -> some View {
        if let prompt = model.prompts[worker.id], model.supportsAnswer {
            box {
                Text(L("Il prompt, come lo vede il lavoratore")).font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTheme.muted)
                Text(prompt.text).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                HStack { ForEach(prompt.options) { option in Button(option.label) { model.answer(task: worker.id, option: option, prompt: prompt) }.buttonStyle(DeckButtonStyle(small: true)).disabled(model.running[worker.id] != nil) } }
            }
        } else {
            box {
                Text(L(model.supportsAnswer ? "Il prompt non si legge ancora: ecco il terminale." : "Rispondere da qui non è ancora disponibile: ecco il terminale. Aprilo per rispondere.")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
                tailBox(worker.id)
                Button(L("Apri il terminale")) { model.openTerminal(worker.meta) }.buttonStyle(DeckButtonStyle(primary: true, small: true))
            }
        }
    }

    private func reviewBox(_ worker: Worker) -> some View {
        box {
            Text(L("Ultimi eventi")).font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTheme.muted)
            ForEach(Array(worker.events.suffix(4).enumerated()), id: \.offset) { _, event in
                Text(D(event.verb + ": " + WorkerBoard.firstLine(event.text, limit: 260))).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            tailBox(worker.id)
        }
    }

    // MARK: buttons

    @ViewBuilder private func buttons(_ worker: Worker) -> some View {
        let busy = model.running[worker.id]
        HStack(spacing: 8) {
            if let busy { ProgressView().controlSize(.small); Text(D(busy)).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            if worker.crew?.kind == .blocked { Button(L("Rispondi")) { model.toggle(.answer, for: worker.id) }.buttonStyle(DeckButtonStyle(primary: true, small: true)) }
            if worker.openDecisions.count > 0, worker.group == .needsYou { Button(L("Vai alle decisioni")) { openDecisions() }.buttonStyle(DeckButtonStyle(primary: worker.crew?.kind != .blocked, small: true)) }
            if worker.refusedCleanup != nil { Button(L("Scarta e pulisci")) { confirm = .discard(worker) }.buttonStyle(DeckButtonStyle(small: true, danger: true)) }
            if worker.group == .done { sweepButton(worker, primary: true) }
            if worker.group == .stale {
                Button(L(model.panel[worker.id] == .review ? "Chiudi la revisione" : "Rivedi e sweep")) { model.toggle(.review, for: worker.id) }.buttonStyle(DeckButtonStyle(primary: model.panel[worker.id] != .review, small: true))
                if model.panel[worker.id] == .review { sweepButton(worker, primary: true) }
            }
            Button(L("Guida")) { model.toggle(.steer, for: worker.id) }.buttonStyle(DeckButtonStyle(small: true))
            Button(L("Terminale")) { model.toggle(.peek, for: worker.id) }.buttonStyle(DeckButtonStyle(small: true))
            openMenu(worker)
            Spacer()
            controlMenu(worker)
        }.disabled(busy != nil)
    }

    private func sweepButton(_ worker: Worker, primary: Bool) -> some View {
        Button(L("Sweep")) { if let click = WorkerActions.sweepClick(worker) { sendCleanup(click.actionID, worker.id, click.draftText, label: L("Sweep \(worker.id)")) } }
            .buttonStyle(DeckButtonStyle(primary: primary, small: true)).disabled(!worker.sweepable)
            .help(worker.sweepBlocker.map { D($0) } ?? L("Segna il risultato come visto e chiude il lavoratore"))
    }

    private func openMenu(_ worker: Worker) -> some View {
        Menu(L("Apri")) {
            Button(L("Pannello del terminale")) { model.openTerminal(worker.meta) }.disabled(worker.meta.herdrTab == nil)
            Button(L("Copia locale nell’editor")) { model.openEditor(worker.meta) }.disabled(worker.meta.worktree.isEmpty)
            if let report = model.reportURL(worker.meta) { Button(L("Rapporto")) { NSWorkspace.shared.open(report) } }
            if let mr = model.mrURL(worker) { Button(L("Merge request")) { NSWorkspace.shared.open(mr) } }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
    }

    private func controlMenu(_ worker: Worker) -> some View {
        Menu(L("Controllo")) {
            Button(L("Interrompi il turno")) { confirm = .interrupt(worker) }
            Button(L("Ferma l’agente (la copia locale resta)")) { confirm = .exit(worker) }
            Button(L("Rilancia con una nota…")) { model.toggle(.relaunch, for: worker.id) }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
    }

    // MARK: confirm and send

    private func alert(_ item: Confirm) -> Alert {
        switch item {
        case .sweepAll(let list):
            // Split into typed steps: as one expression it exceeds the type checker's time limit on the CI toolchain.
            let lines: [String] = list.prefix(8).map { (worker: Worker) -> String in
                let verdict: String = worker.verdict.map { WorkerBoard.firstLine($0, limit: 90) } ?? ""
                return "• " + worker.id + ": " + verdict
            }
            let message: String = lines.joined(separator: "\n") + (list.count > 8 ? "\n…" : "")
            let sweep: () -> Void = {
                for worker in list {
                    guard let click = WorkerActions.sweepClick(worker) else { continue }
                    sendCleanup(click.actionID, worker.id, click.draftText, label: L("Sweep \(worker.id)"))
                }
            }
            return Alert(title: Text(L("Sweep di \(list.count) lavoratori?")), message: Text(message),
                         primaryButton: .default(Text(L("Sweep")), action: sweep),
                         secondaryButton: .cancel(Text(L("Annulla"))))
        case .discard(let worker):
            return Alert(title: Text(L("Scartare \(worker.id) e pulire?")),
                         message: Text(L("Si perde:") + "\n" + WorkerActions.discardLoss(worker).map { "• " + $0 }.joined(separator: "\n")),
                         primaryButton: .destructive(Text(L("Scarta e pulisci"))) { sendCleanup(WorkerActions.discard, worker.id, nil, label: L("Scarta \(worker.id)")) },
                         secondaryButton: .cancel(Text(L("Annulla"))))
        case .exit(let worker):
            return Alert(title: Text(L("Fermare l’agente di \(worker.id)?")), message: Text(L("Il terminale, la copia locale e le modifiche non salvate restano.")),
                         primaryButton: .default(Text(L("Ferma"))) { model.control(.exit, task: worker.id) }, secondaryButton: .cancel(Text(L("Annulla"))))
        case .interrupt(let worker):
            return Alert(title: Text(L("Interrompere il turno di \(worker.id)?")), message: Text(L("L’agente resta acceso.")),
                         primaryButton: .default(Text(L("Interrompi"))) { model.control(.interrupt, task: worker.id) }, secondaryButton: .cancel(Text(L("Annulla"))))
        }
    }

    private func sendCleanup(_ action: String, _ task: String, _ text: String?, label: String) {
        guard WorkerActions.mayRun(action, task: task, ledger: store.commandLedger) else { return }
        feedback = store.sendCompanionClick(actionID: action, target: WorkerActions.target(task), draftText: text, label: text == nil ? label : nil)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = DeckLanguage.current.locale; formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
